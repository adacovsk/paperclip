#!/usr/bin/env bash
# Unit test for freshness-reverify-needed.sh against a throwaway git repo.
#
# Each case builds a task branch on a base, then advances main, and asks whether
# that advance can interact with the branch.
#
# Run: bash agents/architect/freshness-reverify-needed.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/freshness-reverify-needed.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
export XDG_CACHE_HOME="$DIR/cache"; mkdir -p "$XDG_CACHE_HOME/paperclip-verify"
PASS=0; FAIL=0
check() { [ "$2" = "$3" ] && { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; } \
                         || { FAIL=$((FAIL+1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"; }; }

cd "$DIR"
git init -q -b main repo && cd repo && git config user.email t@t && git config user.name t
mkdir -p src/combat src/resources/monster_data assets/data/en/monsters/core assets/data/en/feats docs scripts
cat > src/combat/mod.rs <<'RS'
pub enum Condition {
    Prone,
}

pub fn strike_bonus() -> i32 {
    1
}

pub trait Describe {}
RS
cat > src/resources/monster_data/mod.rs <<'RS'
pub const MONSTERS: &str = "data/en/monsters";

pub fn load() -> i32 {
    0
}
RS
echo 'pub fn other() -> i32 { 2 }' > src/other.rs
echo 'pub const FEATS: &str = "data/en/feats";' > src/resources/feat_data.rs
echo '{"cube": {"damage_immunities": []}}' > assets/data/en/monsters/core/underground.monsters.json
echo '{"wolf": {"speed": 30}}' > assets/data/en/monsters/core/forest.monsters.json
echo '{"blade": {"name": "Blade"}}' > assets/data/en/feats/core.feats.json
echo a > docs/ROADMAP.md && echo a > README.md && echo '[package]' > Cargo.toml
git add -A && git commit -qm base
BASE=$(git rev-parse HEAD)

# A task branch in its own worktree, branched from BASE with one change.
task() {  # task <name> <file> <content-to-append>
  git worktree add -q -b "task/$1" "$DIR/$1" "$BASE"
  (cd "$DIR/$1" && mkdir -p "$(dirname "$2")" && printf '%s\n' "$3" >> "$2" && git add -A && git commit -qm "$1")
}
# Advance main from BASE with one change; prints the new main.
advance() {  # advance <file> <content-to-append>
  git checkout -q --detach "$BASE"
  mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" >> "$1" && git add -A && git commit -qm "main $1"
  git rev-parse HEAD
}
run() { (cd "$DIR/$1" && bash "$SUT" "$BASE" "$2" 2>/dev/null; echo $?); }

task t-other src/other.rs 'pub fn unrelated_helper() -> i32 { 3 }'

echo "documentation"
check "a docs-only advance does not re-verify" "$(run t-other "$(advance docs/ROADMAP.md x)")" 1
check "a Markdown file anywhere is documentation" "$(run t-other "$(advance README.md x)")" 1
check "no change at all does not re-verify" "$(run t-other "$BASE")" 1

echo "where the diffs meet"
check "build-wide input re-verifies" "$(run t-other "$(advance Cargo.toml 'x = 1')")" 0
check "same file re-verifies" "$(run t-other "$(advance src/other.rs 'pub fn more() -> i32 { 4 }')")" 0

git worktree add -q -b task/t-cond "$DIR/t-cond" "$BASE"
(cd "$DIR/t-cond" && sed -i 's/^    Prone,$/    Prone,\n    Grabbed,/' src/combat/mod.rs && git commit -qam "add a variant")
check "main adds a caller of a type the branch edits" \
  "$(run t-cond "$(advance src/other.rs 'pub fn uses() -> Option<Condition> { None }')")" 0

task t-call src/other.rs 'pub fn caller() -> i32 { strike_bonus() }'
MAIN_BODY=$(git checkout -q --detach "$BASE" && sed -i 's/^    1$/    2/' src/combat/mod.rs && git commit -qam body && git rev-parse HEAD)
check "main edits the body of a fn the branch calls" "$(run t-call "$MAIN_BODY")" 0

task t-data assets/data/en/monsters/core/forest.monsters.json '{"ant": {"damage_immunities": ["swarm-mind"]}}'
check "both change data in one directory" \
  "$(run t-data "$(advance assets/data/en/monsters/core/underground.monsters.json '{"jelly": {}}')")" 0
check "main changes the Rust that loads the branch's data" \
  "$(run t-data "$(advance src/resources/monster_data/mod.rs 'pub fn ceiling() -> i32 { 4 }')")" 0

echo "no interaction lands"
task t-schema assets/schemas/monsters.schema.json '{"description": "branch"}'
check "two branches regenerating one schema do not meet" \
  "$(run t-schema "$(advance assets/schemas/monsters.schema.json '{"description": "main"}')")" 1
task t-top assets/data/en/alert_states.json '{"calm": {}}'
check "two top-level data files are two datasets" \
  "$(run t-top "$(advance assets/data/en/loot_tables.json '{"chest": {}}')")" 1
git worktree add -q -b task/t-impl "$DIR/t-impl" "$BASE"
(cd "$DIR/t-impl" && printf 'pub fn knock(c: Condition) -> Condition { c }\n' >> src/other.rs && git commit -qam impl)
MAIN_IMPL=$(git checkout -q --detach "$BASE" && printf '\nimpl Condition {\n    pub fn label_text(&self) -> u8 {\n        0\n    }\n}\n' >> src/combat/mod.rs && git commit -qam impl && git rev-parse HEAD)
check "a method added to a type the branch names does not meet" "$(run t-impl "$MAIN_IMPL")" 1
echo "but a trait impl does"
task t-trait src/other.rs 'impl Describe for i32 {}'
check "both implementing one trait meet" "$(run t-trait "$(advance src/combat/mod.rs 'impl Describe for u8 {}')")" 0
check "unrelated Rust does not re-verify" \
  "$(run t-data "$(advance src/combat/mod.rs 'pub fn flanking_bonus() -> i32 { 2 }')")" 1
check "unrelated data does not re-verify" \
  "$(run t-cond "$(advance assets/data/en/feats/core.feats.json '{"axe": {"name": "Axe"}}')")" 1
check "a comment edit names nothing" \
  "$(run t-other "$(advance src/combat/mod.rs '// strike_bonus and unrelated_helper are fine')")" 1
check "std names do not count as meeting" \
  "$(run t-other "$(advance src/combat/mod.rs 'pub fn maybe() -> Option<i32> { Some(1) }')")" 1

echo "the branch already synced onto the new main"
NEW=$(advance src/combat/mod.rs 'pub fn flanking_bonus() -> i32 { 2 }')
git worktree add -q -b task/t-synced "$DIR/t-synced" "$NEW"
(cd "$DIR/t-synced" && echo 'pub fn unrelated_helper() -> i32 { 3 }' >> src/other.rs && git commit -qam synced)
check "is judged on its own diff, not main's" "$(run t-synced "$NEW")" 1

echo "fails closed"
check "an unreadable old base" "$( (cd "$DIR/t-other" && bash "$SUT" 0000000000000000000000000000000000000000 "$NEW" 2>/dev/null; echo $?) )" 0
git worktree add -q -b task/t-orphan "$DIR/t-orphan" "$NEW" && (cd "$DIR/t-orphan" && git checkout -q --orphan lone && git commit -qm lone --allow-empty)
check "a branch that descends from neither base" "$(run t-orphan "$NEW")" 0
task t-unread assets/data/en/spells/core.spells.json '{"bolt": {}}'
check "data no Rust names, with Rust changed on main" \
  "$(run t-unread "$(advance src/combat/mod.rs 'pub fn flanking_bonus() -> i32 { 2 }')")" 0

echo "and says why"
Z=$(advance src/other.rs 'pub fn z() -> i32 { 9 }')
(cd "$DIR/t-other" && bash "$SUT" "$BASE" "$Z" 2>&1 >/dev/null) | grep -q '^freshness: same file: src/other.rs$'
check "the deciding rule on stderr" "$?" 0
check "and in freshness.log" "$(tail -1 "$XDG_CACHE_HOME/paperclip-verify/freshness.log" | grep -c "task/t-other .* 0 same file: src/other.rs$")" 1

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
