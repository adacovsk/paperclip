#!/usr/bin/env bash
# Tests for reap-verify.sh (AA-3253).
#
# The load-bearing property is the SENTINEL ORDERING: writing 100 before the kill
# must survive the wrapper's own signal trap. If it does not, the trap writes 99,
# the Architect reads 99 as "inconclusive, relaunch", and the reap costs a build
# while freeing nothing. Test 4 exercises that against the real trap text.
#
# Run: bash agents/architect/reap-verify.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
R="$HERE/reap-verify.sh"
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
fails=0
ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }

export XDG_CACHE_HOME="$D/cache"
export PAPERCLIP_PROJECT="$D/proj"
V="$XDG_CACHE_HOME/paperclip-verify"
mkdir -p "$V" "$PAPERCLIP_PROJECT/.paperclip/worktrees"

# A throwaway project repo with a main and two branches: one that merges clean,
# one that conflicts.
git init -q "$PAPERCLIP_PROJECT"
git -C "$PAPERCLIP_PROJECT" config user.email t@t; git -C "$PAPERCLIP_PROJECT" config user.name t
echo base > "$PAPERCLIP_PROJECT/f.txt"; echo shared > "$PAPERCLIP_PROJECT/g.txt"
git -C "$PAPERCLIP_PROJECT" add -A >/dev/null; git -C "$PAPERCLIP_PROJECT" commit -qm base
git -C "$PAPERCLIP_PROJECT" branch -M main
git -C "$PAPERCLIP_PROJECT" remote add origin "$PAPERCLIP_PROJECT"
git -C "$PAPERCLIP_PROJECT" update-ref refs/remotes/origin/main HEAD
mk_wt() { # $1=id  $2=file  $3=content
  git -C "$PAPERCLIP_PROJECT" worktree add -q -b "task/$1" \
    "$PAPERCLIP_PROJECT/.paperclip/worktrees/$1" main
  echo "$3" > "$PAPERCLIP_PROJECT/.paperclip/worktrees/$1/$2"
  git -C "$PAPERCLIP_PROJECT/.paperclip/worktrees/$1" add -A >/dev/null
  git -C "$PAPERCLIP_PROJECT/.paperclip/worktrees/$1" commit -qm "$1"
}
mk_wt AA-1001 own.txt clean          # touches a file main does not
mk_wt AA-1002 g.txt   branch-side    # will conflict once main moves g.txt
echo main-side > "$PAPERCLIP_PROJECT/g.txt"
git -C "$PAPERCLIP_PROJECT" commit -qam moved
git -C "$PAPERCLIP_PROJECT" update-ref refs/remotes/origin/main HEAD

# --- 1. reason allowlist ---------------------------------------------------
if bash "$R" AA-1001 because-i-said-so --dry-run >/dev/null 2>&1; then
  fail "an unknown reason was accepted"
else
  [ "$?" -eq 2 ] && ok "an unknown reason is rejected (exit 2)" || ok "an unknown reason is rejected"
fi

# --- 2. unlandable is PROVEN, not trusted ----------------------------------
# The ticket proposed reaping on `blocked` because "clearing the block needs a
# rebase, which invalidates the build". Measured on live data, two blocked tasks
# both merged CLEAN — so the inference is unsound and the script must re-prove it.
if bash "$R" AA-1001 unlandable --dry-run >/dev/null 2>&1; then
  fail "unlandable was accepted for a branch that merges clean"
else
  ok "unlandable REFUSED for a branch that merges clean"
fi
if bash "$R" AA-1002 unlandable --dry-run >/dev/null 2>&1; then
  ok "unlandable accepted for a branch that genuinely conflicts"
else
  fail "unlandable refused for a branch that genuinely conflicts"
fi

# --- 3. worktree-gone is proven too ----------------------------------------
bash "$R" AA-1001 worktree-gone --dry-run >/dev/null 2>&1 \
  && fail "worktree-gone accepted while the worktree exists" \
  || ok "worktree-gone REFUSED while the worktree exists"
bash "$R" AA-9999 worktree-gone --dry-run >/dev/null 2>&1 \
  && ok "worktree-gone accepted for a worktree that is really gone" \
  || fail "worktree-gone refused for an absent worktree"

# --- 4. THE ORDERING: 100 survives the wrapper's own trap ------------------
# Stand up a process carrying the real trap text from the launch block, reap it,
# and require the sentinel to still read 100. A 99 here means the Architect would
# relaunch the build we just killed.
S="$V"; ID=AA-1003
mkdir -p "$PAPERCLIP_PROJECT/.paperclip/worktrees/$ID"
rm -f "$S/$ID.exit"
setsid bash -c '
  S="'"$S"'"
  _sentinel(){ [ -f "$S/'"$ID"'.exit" ] || echo 99 > "$S/'"$ID"'.exit"; }
  _killed(){ echo "KILLED"; _sentinel; exit 99; }
  trap _sentinel EXIT; trap _killed HUP INT TERM
  echo $$ > "$S/'"$ID"'.pid"
  while :; do sleep 0.2; done
' >/dev/null 2>&1 &
sleep 0.6
victim="$(cat "$S/$ID.pid" 2>/dev/null || echo)"
# Reap the way the script does: sentinel first, then signal the group.
printf '100\n' > "$S/$ID.exit"
[ -n "$victim" ] && kill -TERM "-$(ps -o pgid= -p "$victim" | tr -d ' ')" 2>/dev/null
sleep 0.6
got="$(cat "$S/$ID.exit" 2>/dev/null)"
[ "$got" = "100" ] \
  && ok "sentinel 100 survives the wrapper trap (no spurious relaunch)" \
  || fail "sentinel is '$got', not 100 — the trap overwrote it and the build would relaunch"

# Control: without the pre-write, the trap wins and produces the relaunch code.
ID=AA-1004; rm -f "$S/$ID.exit"
setsid bash -c '
  S="'"$S"'"
  _sentinel(){ [ -f "$S/'"$ID"'.exit" ] || echo 99 > "$S/'"$ID"'.exit"; }
  _killed(){ _sentinel; exit 99; }
  trap _sentinel EXIT; trap _killed HUP INT TERM
  echo $$ > "$S/'"$ID"'.pid"
  while :; do sleep 0.2; done
' >/dev/null 2>&1 &
sleep 0.6
victim="$(cat "$S/$ID.pid" 2>/dev/null || echo)"
[ -n "$victim" ] && kill -TERM "-$(ps -o pgid= -p "$victim" | tr -d ' ')" 2>/dev/null
sleep 0.6
[ "$(cat "$S/$ID.exit" 2>/dev/null)" = "99" ] \
  && ok "control: killing WITHOUT the pre-write yields 99 (the relaunch code)" \
  || fail "control did not produce 99 — the ordering test proves nothing"

# --- 5. a reap with no live build still writes the sentinel ----------------
# Otherwise a wake already in flight relaunches into the slot we just freed.
ID=AA-1005; rm -f "$S/$ID.exit"
bash "$R" "$ID" pr-merged >/dev/null 2>&1
[ "$(cat "$S/$ID.exit" 2>/dev/null)" = "100" ] \
  && ok "a reap with no live build still writes 100" \
  || fail "no sentinel written when there was no live build"

echo
[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAIL ($fails)"; exit 1; }
