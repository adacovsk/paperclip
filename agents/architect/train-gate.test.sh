#!/usr/bin/env bash
# Unit test for train-gate.sh. Real git against a local bare origin; `gh` and
# the cargo semaphore are stubbed, so nothing touches the network or compiles.
#
# What is under test is the gate's one promise: a stack merges only when the
# tree it will put on main is the tree that went green. Every way that tree can
# drift — main moving, a PR head moving, a resolution pushed onto the stack —
# must turn a green record into a refusal.
#
# Run: bash agents/architect/train-gate.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TG="$HERE/train-gate.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"
export TRAIN_GATE_DIR="$DIR/gate" TRAIN_GATE_SEM="$BIN/sem" TRAIN_GATE_REPO=o/r
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s (%s)\n' "$1" "$2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected $3, got $2"; }

O="$DIR/origin.git"; W="$DIR/work"; L="$DIR/local"
g()  { git -C "$W" "$@"; }

# The semaphore stub records each cargo invocation and fails the one named in
# SEM_FAIL, so a red clippy or a red test can be staged.
cat > "$BIN/sem" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DIR/sem.log"
case "\$*" in *"\${SEM_FAIL:-<none>}"*) exit 101 ;; esac
exit 0
EOF
# gh: PR state from $DIR/pr/<n>.state, heads from origin's refs/pull/<n>/head.
# `pr merge` merges into origin main the way GitHub does (parents: main, head)
# and honours --match-head-commit. MOVE_MAIN_BEFORE=<n> lands an unrelated
# commit on main just before PR <n> merges.
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
n="\$3"
head="\$(git -C "$O" rev-parse "refs/pull/\$n/head")"
case "\$1 \$2" in
  "pr view") printf '%s %s\n' "\$(cat "$DIR/pr/\$n.state" 2>/dev/null || echo OPEN)" "\$head" ;;
  "pr merge")
    match="\$(printf '%s\n' "\$@" | grep -A1 -x -- --match-head-commit | tail -1)"
    [ "\$match" = "\$head" ] || exit 1
    m="$DIR/merger"; rm -rf "\$m"; git clone -q "$O" "\$m"
    if [ "\${MOVE_MAIN_BEFORE:-}" = "\$n" ]; then
      echo intruder > "\$m/intruder.txt"; git -C "\$m" add intruder.txt; git -C "\$m" commit -qm intruder
    fi
    git -C "\$m" fetch -q origin "refs/pull/\$n/head"
    git -C "\$m" merge -q --no-ff --no-edit FETCH_HEAD || exit 1
    git -C "\$m" push -q origin HEAD:main
    echo MERGED > "$DIR/pr/\$n.state" ;;
esac
EOF
chmod +x "$BIN/sem" "$BIN/gh"
export PATH="$BIN:$PATH"

# setup: main has a.rs; PR 1 adds b.rs, PR 2 (stacked on 1) adds c.rs.
setup() {
  rm -rf "$O" "$W" "$L" "$DIR/pr" "$DIR/sem.log" "$TRAIN_GATE_DIR"; mkdir -p "$DIR/pr"
  git init -q --bare -b main "$O"
  git init -q -b main "$W"; g remote add origin "$O"
  echo a > "$W/a.rs"; g add a.rs; g commit -qm base; g push -q origin main
  g checkout -qb train/1/A; echo b > "$W/b.rs"; g add b.rs; g commit -qm A
  g push -q origin HEAD:refs/pull/1/head
  g checkout -qb train/1/B; echo c > "$W/c.rs"; g add c.rs; g commit -qm B
  g push -q origin HEAD:refs/pull/2/head
  g checkout -q main
  git clone -q "$O" "$L"
}
tg() { ( cd "$L" && "$TG" "$@" >"$DIR/out" 2>&1 ); }
said() { grep -c -- "$1" "$DIR/out"; }
main_moves() {  # an unrelated commit lands on origin main
  g checkout -q main; g pull -q origin main; echo "$1" > "$W/$1.txt"; g add "$1.txt"; g commit -qm "$1"; g push -q origin main
}

echo "check before verify:"
setup
tg check 1 2;                                 check "no record -> 3" "$?" 3
check "  ...names the verify command" "$(said 'train-gate.sh verify 1 2')" 1

echo "verify:"
tg verify 1 2;                                check "green build -> 0" "$?" 0
check "  ...both gates ran, each its own slot" "$(grep -c '^env CARGO_INCREMENTAL=0 cargo' "$DIR/sem.log")" 2
check "  ...clippy carries the Architect's flags" "$(grep -c -- '-D warnings -A dead-code -A unused-imports' "$DIR/sem.log")" 1
tg check 1 2;                                 check "check after green verify -> 0" "$?" 0
check "  ...scratch worktree removed" "$(ls -d "$TRAIN_GATE_DIR"/wt-* 2>/dev/null | wc -l)" 0
check "  ...verified the merge, not a branch" "$(cd "$L" && "$TG" tree 1 2)" "$(git -C "$L" merge-tree --write-tree origin/main refs/train-gate/pr/2)"

setup
SEM_FAIL="cargo clippy" tg verify 1 2;        check "red clippy -> 1" "$?" 1
tg check 1 2;                                 check "  ...and no record" "$?" 3
setup
SEM_FAIL="cargo test" tg verify 1 2;          check "red test -> 1" "$?" 1

echo "the record stops applying when the tree moves:"
setup; tg verify 1 2
main_moves m1
tg check 1 2;                                 check "main moved after verify -> 3" "$?" 3
setup; tg verify 1 2
g checkout -q train/1/B; echo resolved >> "$W/c.rs"; g commit -qam resolution; g push -q -f origin HEAD:refs/pull/2/head
tg check 1 2;                                 check "resolution pushed onto the top PR -> 3" "$?" 3

echo "unfit stacks:"
setup
tg check 2 1;                                 check "stack listed top-down -> 4" "$?" 4
echo CLOSED > "$DIR/pr/1.state"
tg check 1 2;                                 check "a PR not open -> 4" "$?" 4
setup
g checkout -q main; echo conflict > "$W/c.rs"; g add c.rs; g commit -qm clash; g push -q origin main
tg verify 1 2;                                check "stack conflicts with main -> 4" "$?" 4
check "  ...says resolve on the train branch" "$(said 'resolve on the train branch')" 1
tg;                                           check "no subcommand -> 2" "$?" 2

echo "merge:"
setup
tg merge 1 2;                                 check "merge without a record -> 3" "$?" 3
check "  ...nothing merged" "$(cat "$DIR/pr/1.state" 2>/dev/null || echo OPEN)" OPEN
tg verify 1 2; VERIFIED="$(cat "$DIR/out" | sed -n 's/^GREEN: tree \([0-9a-f]*\).*/\1/p')"
tg merge 1 2;                                 check "verified stack merges -> 0" "$?" 0
check "  ...main carries the verified tree" "$(git -C "$O" rev-parse 'main^{tree}')" "$VERIFIED"

setup; tg verify 1 2
# Another merge lands inside the window between the check and PR 1's merge.
MOVE_MAIN_BEFORE=1 tg merge 1 2;              check "main moves under the stack -> 5" "$?" 5
check "  ...says main moved" "$(said 'main moved under the stack')" 1
check "  ...the PR above it is left open" "$(cat "$DIR/pr/2.state" 2>/dev/null || echo OPEN)" OPEN

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
