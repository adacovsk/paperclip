#!/usr/bin/env bash
# Unit test for freshness-reverify-needed.sh against a throwaway git repo.
#
# Run: bash agents/architect/freshness-reverify-needed.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/freshness-reverify-needed.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
PASS=0; FAIL=0
check() { [ "$2" = "$3" ] && { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; } \
                         || { FAIL=$((FAIL+1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"; }; }

cd "$DIR"
git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p src docs/roadmap && echo a > src/lib.rs && echo a > docs/ROADMAP.md && echo a > README.md
git add -A && git commit -qm base
BASE=$(git rev-parse HEAD)

commit() { echo "$RANDOM" >> "$1"; git add -A; git commit -qm "$1"; git rev-parse HEAD; }
run()    { bash "$SUT" "$1" "$2"; echo $?; }

ROADMAP=$(commit docs/ROADMAP.md)
check "a roadmap-only advance does not re-verify" "$(run "$BASE" "$ROADMAP")" 1

DETAIL=$(mkdir -p docs/roadmap && commit docs/roadmap/4.1.md)
check "roadmap detail files are documentation too" "$(run "$BASE" "$DETAIL")" 1

ROOTMD=$(commit README.md)
check "a Markdown file anywhere is documentation" "$(run "$BASE" "$ROOTMD")" 1

check "no change at all does not re-verify" "$(run "$ROOTMD" "$ROOTMD")" 1

CODE=$(commit src/lib.rs)
check "a source change re-verifies" "$(run "$BASE" "$CODE")" 0
check "docs plus source re-verifies" "$(run "$ROADMAP" "$CODE")" 0

check "an unreadable old base fails closed" "$(run 0000000000000000000000000000000000000000 "$CODE")" 0

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
