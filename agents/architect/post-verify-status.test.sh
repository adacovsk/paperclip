#!/usr/bin/env bash
# Unit test for post-verify-status.sh. Real git against a local bare origin;
# `gh` is stubbed, so nothing touches the network.
#
# What is under test is the script's one promise: a green `pipeline/verify` is
# posted only on a SHA that the named check actually covers. A Rust diff must
# not pass on the landing gate alone, and a carried status must not cross to a
# different tree or from a commit that was never green.
#
# Run: bash agents/architect/post-verify-status.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PVS="$HERE/post-verify-status.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"
export PIPELINE_VERIFY_REPO=o/r
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s (%s)\n' "$1" "$2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected $3, got $2"; }

# gh: a POST to statuses/<sha> appends "<sha> <description>" to posts.log and
# records the state; a GET of commits/<sha>/status answers from that record.
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
path="\$2"; [ "\$1" = api ] && [ "\$2" = -X ] && path="\$4"
case "\$path" in
  repos/o/r/statuses/*)
    sha="\${path##*/}"
    desc="\$(printf '%s\n' "\$@" | sed -n 's/^description=//p')"
    printf '%s %s\n' "\$sha" "\$desc" >> "$DIR/posts.log"
    echo success > "$DIR/state.\$sha" ;;
  repos/o/r/commits/*/status)
    sha="\${path#repos/o/r/commits/}"; sha="\${sha%/status}"
    cat "$DIR/state.\$sha" 2>/dev/null ;;
esac
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

O="$DIR/origin.git"; W="$DIR/work"
git init -q --bare -b main "$O"
git clone -q "$O" "$W" 2>/dev/null
cd "$W" || exit 1
echo a > README.md; git add README.md; git commit -qm base; git push -q origin HEAD:main
git fetch -q origin
posts() { wc -l < "$DIR/posts.log" 2>/dev/null | tr -d ' ' || echo 0; }
[ -f "$DIR/posts.log" ] || : > "$DIR/posts.log"

echo "nocargo"
git checkout -qb data origin/main
mkdir -p assets; echo '{}' > assets/x.json; git add assets; git commit -qm data
DATA="$(git rev-parse HEAD)"
"$PVS" nocargo "$DATA" "landing gate green" >/dev/null; check "data-only diff posts" "$?" 0
check "one post" "$(posts)" 1
grep -q "^$DATA landing gate green (main " "$DIR/posts.log" && ok "description names the base" || bad "description names the base" "$(cat "$DIR/posts.log")"

for f in src/lib.rs Cargo.toml Cargo.lock build.rs rust-toolchain.toml .cargo/config.toml crates/x/Cargo.toml; do
  git checkout -q -B rust origin/main
  mkdir -p "$(dirname "$f")"; echo x > "$f"; git add "$f"; git commit -qm "touch $f"
  before="$(posts)"
  "$PVS" nocargo HEAD "landing gate green" 2>/dev/null; check "refuses a diff touching $f" "$?" 1
  check "nothing posted for $f" "$(posts)" "$before"
done

echo "cargo"
before="$(posts)"
"$PVS" cargo HEAD "clippy + test --lib green" >/dev/null; check "cargo posts on a Rust diff" "$?" 0
check "one more post" "$(posts)" "$((before+1))"
"$PVS" cargo deadbeef "x" 2>/dev/null; check "unknown sha is usage" "$?" 2
"$PVS" cargo HEAD 2>/dev/null; check "missing desc is usage" "$?" 2

echo "description cap"
long="$(printf 'y%.0s' $(seq 1 200))"
"$PVS" cargo HEAD "$long" >/dev/null
len="$(tail -1 "$DIR/posts.log" | cut -d' ' -f2- | tr -d '\n' | wc -c)"
check "description is capped at 140" "$len" 140

echo "carry"
VERIFIED="$(git rev-parse HEAD)"
# A merge commit whose tree is exactly the verified tip — the Coordinator's
# republish of a rebased tip onto the PR branch.
git checkout -q -b pr origin/main
echo stale > stale.txt; git add stale.txt; git commit -qm stale
git merge -q --no-ff --no-commit -s ours "$VERIFIED" 2>/dev/null
git read-tree -u --reset "$VERIFIED"
git commit -qm "Merge rebased tip onto the PR branch"
SAME="$(git rev-parse HEAD)"
"$PVS" carry "$SAME" "$VERIFIED" "carried" >/dev/null; check "same tree, green source posts" "$?" 0
grep -q "^$SAME carried" "$DIR/posts.log" && ok "posted on the new sha" || bad "posted on the new sha" "missing"

echo more > more.txt; git add more.txt; git commit -qm "unbuilt edit"
before="$(posts)"
"$PVS" carry HEAD "$VERIFIED" "carried" 2>/dev/null; check "refuses a different tree" "$?" 1
check "nothing posted for a different tree" "$(posts)" "$before"

git checkout -q -b twin "$VERIFIED"
git commit -q --allow-empty -m twin
TWIN="$(git rev-parse HEAD)"     # same tree as VERIFIED, but itself never green
git commit -q --allow-empty -m twin2
"$PVS" carry HEAD "$TWIN" "carried" 2>/dev/null; check "refuses a source with no green status" "$?" 1
check "nothing posted from an ungreen source" "$(posts)" "$before"

"$PVS" bogus 2>/dev/null; check "unknown mode is usage" "$?" 2

echo
echo "post-verify-status: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
