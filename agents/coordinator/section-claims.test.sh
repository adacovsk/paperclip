#!/usr/bin/env bash
# Tests for section-claims.py against a fixed task list. No API, no network.
#   bash agents/coordinator/section-claims.test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/section-claims.py"
DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT
FAIL=0

cat > "$DIR/issues.json" <<'EOF'
[{"identifier":"AA-1","status":"in_review","title":"§4.5 — Do the thing","description":""},
 {"identifier":"AA-2","status":"cancelled","title":"§4.6 — Old","description":""},
 {"identifier":"AA-3","status":"done","completedAt":"2020-01-01T00:00:00Z","title":"§4.7 — Ancient","description":""},
 {"identifier":"AA-4","status":"todo","title":"Scale carry limits by size","description":"no section"},
 {"identifier":"AA-5","status":"in_review","parentId":"x","title":"Review: AA-1 §4.5","description":""},
 {"identifier":"AA-6","status":"done","completedAt":"2999-01-01T00:00:00Z","title":"§4.8 — slice one","description":"Where: src/a.rs"},
 {"identifier":"AA-7","status":"in_review","title":"§4.10 — slice in flight","description":""},
 {"identifier":"AA-8","status":"todo","title":"Unrelated §4.50 work","description":"Section: §4.50"}]
EOF

check() {  # check <expected exit> <description> <args...>
  local want="$1" what="$2"; shift 2
  python3 "$S" "$@" --issues-json "$DIR/issues.json" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok   $what"; else echo "FAIL $what (exit $got, want $want)"; FAIL=1; fi
}

check 1 "a live task naming the section claims it"            4.5  --title "anything"
check 0 "a cancelled task claims nothing"                      4.6  --title "anything"
check 0 "a task done long ago claims nothing"                  4.7  --title "anything" --days 7
check 1 "a section-less task with the same title claims it"    4.9  --title "Scale carry limits by size (§4.9)"
check 0 "the candidate does not claim against itself"          4.5  --title "anything" --exclude AA-1
check 0 "a stage subtask is not a claim of its own"            4.5  --title "anything" --exclude AA-1
check 0 "§4.5 does not match §4.50"                            4.5  --title "anything" --exclude AA-1
check 0 "a done slice with disjoint paths leaves room"         4.8  --title "slice two" --slice --paths src/b.rs
check 1 "a done slice that took the same path claims it"       4.8  --title "slice two" --slice --paths src/a.rs
check 1 "a slice still in flight claims the whole front"       4.10 --title "slice two" --slice --paths src/z.rs

python3 "$S" 4.5 --title x --issues-json "$DIR/missing.json" >/dev/null 2>&1
if [ $? = 2 ]; then echo "ok   an unreadable task list fails closed"; else echo "FAIL unreadable task list"; FAIL=1; fi

exit $FAIL
