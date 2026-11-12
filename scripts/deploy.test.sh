#!/usr/bin/env bash
# Tests for deploy.sh.  Run: scripts/deploy.test.sh
# Builds a throwaway origin and live checkout, and stubs pnpm, systemctl and
# curl so each case records what the script would have run.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

setup() {
  rm -rf "$TMP/origin" "$TMP/live" "$TMP/bin" "$TMP/calls"
  mkdir -p "$TMP/bin"
  : > "$TMP/calls"
  for tool in pnpm systemctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$tool" "$TMP" > "$TMP/bin/$tool"
  done
  # live-runs answers with $RUNNING running runs; health always answers.
  cat > "$TMP/bin/curl" <<STUB
#!/bin/sh
case "\$*" in
  *live-runs*) n=\$(cat "$TMP/running" 2>/dev/null || echo 0); i=0; printf '['; while [ \$i -lt \$n ]; do [ \$i -gt 0 ] && printf ','; printf '{"status":"running"}'; i=\$((i+1)); done; printf ']' ;;
  *) printf '{"status":"ok"}' ;;
esac
STUB
  chmod +x "$TMP/bin/"*
  echo 0 > "$TMP/running"
  git init -q -b master "$TMP/origin"
  ( cd "$TMP/origin" && git config user.email t@t && git config user.name t \
    && mkdir -p scripts agents server ui && cp "$HERE/deploy.sh" scripts/ \
    && echo a > agents/a && echo s > server/s && echo u > ui/u && echo l > pnpm-lock.yaml \
    && git add -A && git commit -q -m base )
  git clone -q "$TMP/origin" "$TMP/live"
}

push() {  # push <path>...: change each path on origin
  ( cd "$TMP/origin" && for p in "$@"; do echo "$RANDOM" >> "$p"; done && git add -A && git commit -q -m change )
}

deploy() { ( cd "$TMP/live" && PATH="$TMP/bin:$PATH" ./scripts/deploy.sh "$@" ) > "$TMP/out" 2>&1; }

check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$TMP/out" "$TMP/calls"; fail=1; fi
}
called() { grep -q "$1" "$TMP/calls"; }
not_called() { ! grep -q "$1" "$TMP/calls"; }
at_origin() { [ "$(git -C "$TMP/live" rev-parse HEAD)" = "$(git -C "$TMP/origin" rev-parse HEAD)" ]; }

setup; push agents/a; deploy
check "a pipeline-script change is pulled" at_origin
check "a pipeline-script change restarts nothing" not_called systemctl
check "a pipeline-script change builds nothing" not_called pnpm

setup; push server/s; deploy
check "a server change restarts the server" called "systemctl --user restart paperclip.service"
check "a server change does not rebuild the UI" not_called "ui build"

setup; push ui/u; deploy
check "a UI change rebuilds the UI" called "pnpm --filter @paperclipai/ui build"
check "a UI change does not restart the server" not_called systemctl

setup; push pnpm-lock.yaml; deploy
check "a lockfile change installs" called "pnpm install --frozen-lockfile"
check "a lockfile change restarts the server" called "systemctl --user restart"

setup; deploy
check "nothing new restarts nothing" not_called systemctl
setup; deploy --restart
check "--restart restarts with nothing new" called "systemctl --user restart"

setup; push server/s; deploy --dry-run
check "--dry-run pulls nothing" test "$(git -C "$TMP/live" rev-parse HEAD)" != "$(git -C "$TMP/origin" rev-parse HEAD)"
check "--dry-run restarts nothing" not_called systemctl

setup; push server/s; echo edited >> "$TMP/live/server/s"; deploy
check "a modified tracked file refuses the deploy" grep -q "tracked files are modified" "$TMP/out"
check "a refused deploy restarts nothing" not_called systemctl

setup; push server/s; echo scratch > "$TMP/live/agents/untracked"; deploy
check "an untracked file does not block the deploy" called "systemctl --user restart"

setup; push server/s; git -C "$TMP/live" checkout -q -b other; deploy
check "another branch is not the live checkout" grep -q "not the live checkout" "$TMP/out"

setup; push server/s; echo 2 > "$TMP/running"; deploy
check "runs in flight are named, then the restart goes ahead" grep -q "2 agent run(s) in flight will be killed and retried" "$TMP/out"
check "runs in flight do not stop a deploy without --wait" called "systemctl --user restart"

exit $fail
