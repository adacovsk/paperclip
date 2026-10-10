#!/usr/bin/env bash
# Tests for train-sync.sh.
#
# The load-bearing properties: a bottom PR that conflicts with main is reported
# and never written, with its stack held behind it; once the bottom carries a
# resolution, every PR above gets it by merge in one run, as a fast-forward
# push; a child's own conflict with its base is reported and holds only its
# subtree; a PR stranded on a merged base is retargeted to main, one on an
# unknown base is not; and --dry-run writes nothing.
#
# Run: bash agents/coordinator/train-sync.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/train-sync.sh"
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
fails=0
ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; printf '%s\n' "$OUT" | sed 's/^/       /'; fi; }

export XDG_CACHE_HOME="$D/cache"
export PAPERCLIP_PROJECT="$D/proj"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$D/bin"

# Fake gh: open PRs come from $D/open.json, a merged PR for head H from
# $D/merged/H, and every `pr edit` is logged.
cat > "$D/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "pr list --state open"*) cat "$D/open.json" ;;
  "pr list --state merged --head "*) h="\$6"; [ -f "$D/merged/\$h" ] && cat "$D/merged/\$h" ;;
  "pr edit "*) echo "\$*" >> "$D/edits" ;;
  *) echo "fake gh: unexpected \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$D/bin/gh"
export PATH="$D/bin:$PATH"
mkdir -p "$D/merged"; : > "$D/edits"

git init -q --bare -b main "$D/remote.git"
git clone -q "$D/remote.git" "$D/seed" 2>/dev/null
g() { git -C "$D/seed" "$@"; }
commit() { printf '%s\n' "$2" > "$D/seed/$1"; g add "$1"; g commit -qm "$1: $2"; }
remote_sha() { git -C "$D/remote.git" rev-parse "refs/heads/$1"; }
r_ancestor() { git -C "$D/remote.git" merge-base --is-ancestor "$1" "$2"; }

commit b.txt base; g push -q origin main
g checkout -qb t1; commit b.txt bottom; g push -q origin t1
g checkout -qb t2; commit c.txt child; g push -q origin t2
g checkout -qb t3; commit d.txt grandchild; g push -q origin t3
g checkout -q main; commit b.txt main-moved; g push -q origin main
git clone -q "$D/remote.git" "$PAPERCLIP_PROJECT" 2>/dev/null

pr() { printf '{"number":%s,"headRefName":"%s","baseRefName":"%s","isCrossRepository":false}' "$1" "$2" "$3"; }
echo "[$(pr 1 t1 main),$(pr 2 t2 t1),$(pr 3 t3 t2)]" > "$D/open.json"
T2_0="$(remote_sha t2)"; T3_0="$(remote_sha t3)"

# 1. Bottom conflicts with main → reported, nothing pushed, stack held.
OUT="$(bash "$S" 2>&1)"
check "conflicting bottom is reported with its file" 'grep -q "#1: bottom of stack CONFLICTS with main.*b.txt" <<<"$OUT"'
check "stack above a conflicting bottom waits" 'grep -q "#2: waits on #1" <<<"$OUT" && grep -q "#3: waits on #2" <<<"$OUT"'
check "nothing pushed while the bottom conflicts" '[ "$(remote_sha t2)" = "$T2_0" ] && [ "$(remote_sha t3)" = "$T3_0" ]'

# 2. Resolve once at the bottom → the whole stack picks it up by merge.
g checkout -q t1; g merge -q origin/main >/dev/null 2>&1; printf 'resolved\n' > "$D/seed/b.txt"
g add b.txt; g commit -qm resolve; g push -q origin t1
T1_R="$(remote_sha t1)"

OUT="$(bash "$S" --dry-run 2>&1)"
check "dry run reports the cascade" 'grep -q "#2: would merge #1" <<<"$OUT" && grep -q "#3: would merge #2" <<<"$OUT"'
check "dry run pushes nothing" '[ "$(remote_sha t2)" = "$T2_0" ] && [ "$(remote_sha t3)" = "$T3_0" ]'

OUT="$(bash "$S" 2>&1)"
check "child merged and pushed" 'grep -q "#2: merged #1" <<<"$OUT" && r_ancestor "$T1_R" t2'
check "grandchild gets the child's new tip in the same run" 'grep -q "#3: merged #2" <<<"$OUT" && r_ancestor "$(remote_sha t2)" t3'
check "pushes are fast-forwards" 'r_ancestor "$T2_0" t2 && r_ancestor "$T3_0" t3'
check "child now merges cleanly into main" 'git -C "$D/remote.git" merge-tree --write-tree main t3 >/dev/null'
check "the resolution was not re-done" '[ "$(git -C "$D/remote.git" show t3:b.txt)" = resolved ]'

OUT="$(bash "$S" 2>&1)"
check "an up-to-date stack is a no-op" '[ -z "$OUT" ]'

# 3. A child's own conflict with its base holds only its subtree.
g checkout -q t1; commit c.txt bottom-also; g push -q origin t1
T2_1="$(remote_sha t2)"
OUT="$(bash "$S" 2>&1)"
check "child's own conflict is reported" 'grep -q "#2: CONFLICTS with its base #1 in its own commits: c.txt" <<<"$OUT"'
check "conflicting child is not pushed" '[ "$(remote_sha t2)" = "$T2_1" ]'
check "its subtree waits" 'grep -q "#3: waits on #2" <<<"$OUT"'

# 4. Orphaned bases: merged → retarget; unknown → leave.
echo "[$(pr 1 t1 main),$(pr 4 t4 gone-merged),$(pr 5 t5 gone-unknown)]" > "$D/open.json"
echo 9 > "$D/merged/gone-merged"
OUT="$(bash "$S" --dry-run 2>&1)"
check "dry run does not retarget" '[ ! -s "$D/edits" ] && grep -q "#4: would retarget to main" <<<"$OUT"'
OUT="$(bash "$S" 2>&1)"
check "PR on a merged base is retargeted to main" 'grep -qx "pr edit 4 --base main" "$D/edits"'
check "PR on an unknown base is left alone" '! grep -q "pr edit 5" "$D/edits" && grep -q "#5: base gone-unknown has no open or merged PR" <<<"$OUT"'

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
