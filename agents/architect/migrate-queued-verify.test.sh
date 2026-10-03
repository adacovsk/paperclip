#!/usr/bin/env bash
# Tests for migrate-queued-verify.sh. systemctl, the pace gate and the offload
# are stubbed; the processes inside each "scope" are real, so the compiler check
# reads genuine /proc entries.
#
# The properties that matter: a build with a compiler running is never stopped,
# nothing moves while the lane is closed, and a refused offload leaves no
# sentinel behind, so the Architect relaunches locally instead of reading "reaped".
#
# Run: bash agents/architect/migrate-queued-verify.test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/migrate-queued-verify.sh"
D="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$D"; }
trap cleanup EXIT
PASS=0; FAIL=0
check() { [ "$2" = "$3" ] && { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; } \
                         || { FAIL=$((FAIL+1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"; }; }

export XDG_CACHE_HOME="$D/cache" PAPERCLIP_PROJECT="$D/proj" MIGRATE_CGROUP_ROOT="$D/cg"
V="$XDG_CACHE_HOME/paperclip-verify"; mkdir -p "$V" "$D/bin"
export PATH="$D/bin:$PATH"
export MIGRATE_CLOUD_VERIFY="$D/bin/cloud-verify" MIGRATE_INTERVAL=0

# --- stubs -----------------------------------------------------------------
cat > "$D/bin/systemctl" <<STUB
#!/usr/bin/env bash
shift  # --user
case "\$1" in
  list-units) cat "$D/units" 2>/dev/null ;;
  show)       echo "/u/\$2" ;;
  stop)       echo "\$2" >> "$D/stopped" ;;
esac
STUB
cat > "$D/bin/cloud-verify" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$D/offloaded"
exit "\$(cat "$D/offload_rc" 2>/dev/null || echo 0)"
STUB
cp "$(command -v sleep)" "$D/bin/rustc"
chmod +x "$D/bin/systemctl" "$D/bin/cloud-verify"
pace() { printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$D/bin/pace"; chmod +x "$D/bin/pace"; }
export MIGRATE_PACE="$D/bin/pace"

# A live scope for task $1 whose cgroup holds one process running $2.
scope() {
  local id="$1" prog="$2" pid
  if [ "$prog" = rustc ]; then "$D/bin/rustc" 300 >/dev/null 2>&1 & else bash -c 'A="AA-9'"${id#AA-}"'"; sleep 300; true' >/dev/null 2>&1 & fi
  pid=$!; PIDS+=("$pid"); sleep 0.1
  echo "verifyrun-$id.scope loaded active running" >> "$D/units"
  mkdir -p "$D/cg/u/verifyrun-$id.scope" "$PAPERCLIP_PROJECT/.paperclip/worktrees/$id"
  echo "$pid" > "$D/cg/u/verifyrun-$id.scope/cgroup.procs"
  echo "$pid" > "$V/$id.pid"
}
reset() { rm -f "$D/units" "$D/stopped" "$D/offloaded" "$D/offload_rc" "$V"/*.exit; }

# --- cases -----------------------------------------------------------------
reset; pace 0; scope AA-1 sleep
bash "$SUT" >/dev/null
check "closed lane stops nothing"   "$(cat "$D/stopped" 2>/dev/null | wc -l)" 0
check "closed lane offloads nothing" "$(cat "$D/offloaded" 2>/dev/null | wc -l)" 0

reset; pace 1; scope AA-2 sleep; scope AA-3 rustc
bash "$SUT" >/dev/null
check "a queued build is stopped"            "$(grep -c verifyrun-AA-2 "$D/stopped")" 1
check "a compiling build is left alone"      "$(grep -c verifyrun-AA-3 "$D/stopped")" 0
check "the queued build is offloaded"        "$(grep -c '^offload AA-2 task/AA-2' "$D/offloaded")" 1
check "offload wakes the wrapper's verify task" "$(grep -c 'AA-2 task/AA-2 AA-92$' "$D/offloaded")" 1
check "the compiling build is not offloaded" "$(grep -c 'AA-3' "$D/offloaded")" 0

reset; pace 1; scope AA-4 sleep; echo 1 > "$D/offload_rc"
bash "$SUT" AA-4 >/dev/null
check "a refused offload leaves no sentinel" "$([ -f "$V/AA-4.exit" ] && echo present || echo absent)" absent

reset; pace 1; scope AA-6 sleep; scope AA-7 sleep; echo 1 > "$D/offload_rc"
bash "$SUT" AA-6 AA-7 >/dev/null
check "a refusal stops the run before the next build" "$(grep -c verifyrun-AA-7 "$D/stopped")" 0
check "only the refused build was offered"           "$(wc -l < "$D/offloaded")" 1

reset; pace 1; scope AA-5 sleep
bash "$SUT" --dry-run >/dev/null
check "dry run stops nothing" "$(cat "$D/stopped" 2>/dev/null | wc -l)" 0

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
