#!/usr/bin/env bash
# Unit test for open-draft.sh with gh, the task title, the body generator and
# the body check stubbed.
#
# Run: bash agents/architect/open-draft.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/open-draft.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
PASS=0; FAIL=0
check() { [ "$2" = "$3" ] && { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; } \
                         || { FAIL=$((FAIL+1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"; }; }

export PAPERCLIP_PROJECT="$DIR/proj" XDG_CACHE_HOME="$DIR/cache" PAPERCLIP_GH_USER=u
mkdir -p "$PAPERCLIP_PROJECT/scripts"
CALLS="$DIR/calls"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$DIR/$1"; chmod +x "$DIR/$1"; }
stub gh "case \"\$1 \$2\" in
  'auth switch') exit 0 ;;
  'pr list') [ -z \"\${LIST_RC:-}\" ] || exit \"\$LIST_RC\"; echo \"\${PR_COUNT:-0}\" ;;
  'pr create') echo \"pr-create \$*\" >> $CALLS; [ -z \"\${CREATE_RC:-}\" ] || exit \"\$CREATE_RC\"; echo https://example/pr/9 ;;
esac"
stub title 'printf "%s\n" "${TITLE_SAYS-Do the thing}"'
stub body 'printf "## Verification\n- not built yet\n"; exit ${BODY_RC:-0}'
stub check 'echo "check $*" >> '"$CALLS"'; exit ${CHECK_RC:-0}'
export OPEN_DRAFT_GH="$DIR/gh" OPEN_DRAFT_TITLE="$DIR/title" OPEN_DRAFT_BODY="$DIR/body" OPEN_DRAFT_CHECK="$DIR/check"

run() { : > "$CALLS"; bash "$SUT" T-1 > "$DIR/out" 2>&1; echo $?; }
called() { grep -c "^$1" "$CALLS" | tr -d ' '; }

echo "opens a draft"
check "no PR yet -> 0" "$(run)" 0
check "  created as a draft" "$(called 'pr-create pr create --draft --base main --head task/T-1 --title Do the thing')" 1
check "  body checked as a draft's" "$(called 'check Do the thing')" 1
check "  says where" "$(grep -c 'draft opened: https://example/pr/9' "$DIR/out")" 1

echo "never two PRs"
r=$(PR_COUNT=1 run)
check "a PR exists -> 0" "$r" 0
check "  no create" "$(called pr-create)" 0

echo "every failure is best effort: exit 0, no draft, a reason"
for case in "LIST_RC=1:cannot list PRs" "TITLE_SAYS=:cannot read the task title" \
            "BODY_RC=1:could not build a body" "CHECK_RC=1:rejected the body"; do
  : > "$CALLS"; env "${case%%:*}" bash "$SUT" T-1 > "$DIR/out" 2>&1; r=$?
  check "${case%%:*} -> 0" "$r" 0
  check "  no create" "$(called pr-create)" 0
  check "  says ${case#*:}" "$(grep -c "${case#*:}" "$DIR/out")" 1
done
r=$(CREATE_RC=1 run)
check "create refused -> 0" "$r" 0
check "  says landing will open it" "$(grep -c 'land.sh will open the PR' "$DIR/out")" 1

echo "finds its project from the worktree when PAPERCLIP_PROJECT is unset"
git init -q -b main "$DIR/repo" && mkdir -p "$DIR/repo/scripts"
git -C "$DIR/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$DIR/repo" worktree add -q -b task/T-1 "$DIR/repo/.paperclip/worktrees/T-1"
: > "$CALLS"; (cd "$DIR/repo/.paperclip/worktrees/T-1" && env -u PAPERCLIP_PROJECT bash "$SUT" T-1 > "$DIR/out" 2>&1); r=$?
check "no PAPERCLIP_PROJECT -> 0" "$r" 0
check "  still opened the draft" "$(called 'pr-create pr create --draft')" 1
: > "$CALLS"; (cd "$DIR" && env -u PAPERCLIP_PROJECT bash "$SUT" T-1 > "$DIR/out" 2>&1); r=$?
check "outside any checkout -> 0" "$r" 0
check "  no draft" "$(called pr-create)" 0

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
