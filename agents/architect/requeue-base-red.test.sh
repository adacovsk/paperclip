#!/usr/bin/env bash
# Tests for requeue-base-red.sh.
#
# The load-bearing properties: a marker whose sha is still origin/main is left
# alone (re-running would only reproduce the red); a stale one has its result
# deleted BEFORE the task is re-dispatched, and the marker only AFTER it; the
# re-dispatch toggles the assignee through null (the only thing that fires a
# wake); a verify not yet blocked keeps everything for a later pass; and a
# finished one is cleared but not touched, unless a newer `Verify:` subtask of
# the same task is the one blocked — the marker may still name a cancelled predecessor.
# A marker that records failing sites is requeued only by a commit touching the
# break, not by any move of main; a re-dispatch cut off between the null PATCH
# and the re-assignment is finished by the next sweep; and a second concurrent
# sweep backs off the lock.
#
# Run: bash agents/architect/requeue-base-red.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
R="$HERE/requeue-base-red.sh"
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
fails=0
ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }

export XDG_CACHE_HOME="$D/cache"
export PAPERCLIP_PROJECT="$D/proj"
export PAPERCLIP_API_URL=http://api.invalid
V="$XDG_CACHE_HOME/paperclip-verify"
mkdir -p "$V" "$D/bin"

git init -q "$PAPERCLIP_PROJECT"
git -C "$PAPERCLIP_PROJECT" config user.email t@t; git -C "$PAPERCLIP_PROJECT" config user.name t
git -C "$PAPERCLIP_PROJECT" commit -q --allow-empty -m one; OLD="$(git -C "$PAPERCLIP_PROJECT" rev-parse HEAD)"
git -C "$PAPERCLIP_PROJECT" commit -q --allow-empty -m two; NEW="$(git -C "$PAPERCLIP_PROJECT" rev-parse HEAD)"
git -C "$PAPERCLIP_PROJECT" update-ref refs/remotes/origin/main "$NEW"
# fetch has no remote to reach here; origin/main is set by hand above.
git -C "$PAPERCLIP_PROJECT" remote add origin "$D/nowhere"

# Fake curl: GET answers from $D/issues.json; every call is logged, and the log
# records whether the sentinel still existed at the moment of each PATCH.
cat > "$D/bin/curl" <<EOF
#!/usr/bin/env bash
m=GET; data=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in -X) m="\$2"; shift 2;; -d) data="\$2"; shift 2;; -H) shift 2;; --max-time) shift 2;; -*) shift;; *) url="\$1"; shift;; esac
done
if [ "\$m" = PATCH ]; then
  e=absent; [ -e "$V/T-1.exit" ] && e=present
  echo "PATCH \$url \$data exit=\$e" >> "$D/calls"
elif [ "\$m" = POST ]; then
  echo "POST \$url" >> "$D/calls"
else
  echo "GET \$url" >> "$D/calls"; cat "$D/issues.json"
fi
EOF
chmod +x "$D/bin/curl"
export PATH="$D/bin:$PATH"

reset() { rm -f "$V"/* "$D/calls"; : > "$D/calls"; }

# 1. Marker on current main → untouched.
reset
printf '%s\nV-1\n' "$NEW" > "$V/T-1.base-red"; echo 1 > "$V/T-1.exit"
echo '[]' > "$D/issues.json"
bash "$R" >/dev/null
[ -f "$V/T-1.exit" ] && [ -f "$V/T-1.base-red" ] && ! grep -q PATCH "$D/calls" \
  && ok "marker on current main is left alone" || fail "marker on current main was acted on"

# 2. Stale marker, blocked task → cleared, then re-dispatched via null toggle.
reset
printf '%s\nV-1\n' "$OLD" > "$V/T-1.base-red"
for f in exit cloud.verdict cloud.head; do echo x > "$V/T-1.$f"; done
echo 1 > "$V/V-1.exit"
echo '[{"identifier":"V-10","id":"wrong","status":"blocked","assigneeAgentId":"a"},{"identifier":"V-1","id":"u1","status":"blocked","assigneeAgentId":"arch"}]' > "$D/issues.json"
out="$(bash "$R")"
[ ! -e "$V/T-1.exit" ] && [ ! -e "$V/T-1.cloud.verdict" ] && [ ! -e "$V/T-1.cloud.head" ] \
  && [ ! -e "$V/T-1.base-red" ] && [ ! -e "$V/V-1.exit" ] \
  && ok "stale result and alias deleted" || fail "stale result not fully deleted"
p1="$(grep PATCH "$D/calls" | sed -n 1p)"; p2="$(grep PATCH "$D/calls" | sed -n 2p)"
case "$p1" in *"/issues/u1 "*'"status":"todo","assigneeAgentId":null'*"exit=absent"*) ok "first PATCH: todo + null, after the delete";; *) fail "first PATCH wrong: $p1";; esac
case "$p2" in *"/issues/u1 "*'"assigneeAgentId":"arch"'*) ok "second PATCH restores the assignee";; *) fail "second PATCH wrong: $p2";; esac
case "$out" in *"requeued V-1"*) ok "reports the requeue";; *) fail "no requeue report: $out";; esac
grep -q "^POST .*/issues/u1/comments" "$D/calls" && ok "posts a comment naming what resolved the block" || fail "no resolving comment"

# 3. Stale marker, verify not yet blocked (the Architect writes the marker,
#    then PATCHes `blocked`) → nothing deleted, not patched; a later pass that
#    finds it blocked requeues it.
reset
printf '%s\n' "$OLD" > "$V/T-1.base-red"; echo 1 > "$V/T-1.exit"
echo '[{"identifier":"T-1","id":"u2","status":"in_review","assigneeAgentId":"arch"}]' > "$D/issues.json"
bash "$R" >/dev/null
[ -e "$V/T-1.exit" ] && [ -e "$V/T-1.base-red" ] && ! grep -q PATCH "$D/calls" \
  && ok "not-yet-blocked verify keeps its marker and result" || fail "not-yet-blocked verify was cleared or patched"
echo '[{"identifier":"T-1","id":"u2","status":"blocked","assigneeAgentId":"arch"}]' > "$D/issues.json"
out="$(bash "$R")"
case "$out" in *"requeued T-1"*) ok "a later pass requeues it once blocked";; *) fail "later pass did not requeue: $out";; esac
[ ! -e "$V/T-1.base-red" ] && [ ! -e "$V/T-1.exit" ] && ok "marker removed after the re-dispatch" || fail "marker survived a successful requeue"

# 3b. Stale marker, verify finished → cleared, not patched.
reset
printf '%s\n' "$OLD" > "$V/T-1.base-red"; echo 1 > "$V/T-1.exit"
echo '[{"identifier":"T-1","id":"u2","status":"cancelled","assigneeAgentId":"arch"}]' > "$D/issues.json"
bash "$R" >/dev/null
[ ! -e "$V/T-1.exit" ] && [ ! -e "$V/T-1.base-red" ] && ! grep -q PATCH "$D/calls" \
  && ok "finished verify cleared but not re-dispatched" || fail "finished verify was patched or not cleared"

# 3c. Lookup finds nothing (unknown name or API down) → marker kept.
reset
printf '%s\n' "$OLD" > "$V/T-1.base-red"; echo 1 > "$V/T-1.exit"
echo '[]' > "$D/issues.json"
bash "$R" >/dev/null
[ -e "$V/T-1.base-red" ] && ! grep -q PATCH "$D/calls" \
  && ok "an empty lookup keeps the marker" || fail "an empty lookup cleared the marker"

# 4. Unknown task after a known one → no reuse of the previous marker's ids.
reset
printf '%s\nV-1\n' "$OLD" > "$V/A-1.base-red"; printf '%s\nV-9\n' "$OLD" > "$V/B-1.base-red"
echo '[{"identifier":"V-1","id":"u1","status":"blocked","assigneeAgentId":"arch"}]' > "$D/issues.json"
bash "$R" >/dev/null
[ "$(grep -c PATCH "$D/calls")" = 2 ] && ok "an unknown task does not reuse the previous lookup" \
  || fail "PATCH count $(grep -c PATCH "$D/calls"), expected 2"

# 4b. The cloud launch record is cleared with the sentinel, so the woken
# Architect does not read "launch, no sentinel" as a dead watcher and resume it.
reset
printf '%s\n' "$OLD" > "$V/T-1.base-red"; echo 1 > "$V/T-1.exit"; date +%s > "$V/T-1.cloud.launched"
echo '[{"identifier":"T-1","id":"u1","status":"blocked","assigneeAgentId":"arch"}]' > "$D/issues.json"
bash "$R" >/dev/null
[ ! -e "$V/T-1.cloud.launched" ] && ok "requeue clears the cloud launch record" \
  || fail "cloud launch record survived the requeue"

# 6. Marker names a cancelled predecessor Verify; a newer one re-escalated the
#    same red and is the one blocked → that one is re-dispatched.
reset
printf '%s\nV-1\n' "$OLD" > "$V/T-1.base-red"; echo 1 > "$V/T-1.exit"; echo 1 > "$V/V-2.exit"
echo '[{"identifier":"V-1","id":"u1","status":"cancelled","assigneeAgentId":"arch","title":"Verify: T-1 old","issueNumber":1},
{"identifier":"V-3","id":"u3","status":"blocked","assigneeAgentId":"arch","title":"Verify: T-10 other","issueNumber":3},
{"identifier":"V-2","id":"u2","status":"blocked","assigneeAgentId":"arch","title":"Verify: T-1 newer","issueNumber":2}]' > "$D/issues.json"
out="$(bash "$R")"
p1="$(grep PATCH "$D/calls" | sed -n 1p)"
case "$p1" in *"/issues/u2 "*'"status":"todo","assigneeAgentId":null'*) ok "falls back to the blocked successor Verify";; *) fail "fallback PATCH wrong: $p1";; esac
! grep -q "/issues/u3 " "$D/calls" && ok "a Verify of T-10 is not taken for T-1" || fail "matched the T-10 verify"
[ ! -e "$V/V-2.exit" ] && ok "successor's stale sentinel deleted" || fail "successor sentinel survived"
case "$out" in *"requeued V-2"*) ok "reports the successor";; *) fail "no successor report: $out";; esac

# 7. Marker with a failing site; main moved only by an unrelated commit → left blocked.
reset
g() { git -C "$PAPERCLIP_PROJECT" "$@"; }
mkdir -p "$PAPERCLIP_PROJECT/src"
printf 'struct Ctx { a: i16 }\n' > "$PAPERCLIP_PROJECT/src/def.rs"
printf 'fn f() { let _ = Ctx {}; }\n' > "$PAPERCLIP_PROJECT/src/site.rs"
printf 'x\n' > "$PAPERCLIP_PROJECT/other.txt"
g add -A; g commit -q -m base; B="$(g rev-parse HEAD)"
printf 'y\n' > "$PAPERCLIP_PROJECT/other.txt"; g commit -q -am unrelated
g update-ref refs/remotes/origin/main HEAD
printf '%s\nT-1\nsrc/site.rs:1 E0063 missing field `attack_total` in initializer of `Ctx`\n' "$B" > "$V/T-1.base-red"
echo 1 > "$V/T-1.exit"
echo '[{"identifier":"T-1","id":"u1","status":"blocked","assigneeAgentId":"arch"}]' > "$D/issues.json"
out="$(bash "$R")"
[ -e "$V/T-1.base-red" ] && [ -e "$V/T-1.exit" ] && ! grep -q PATCH "$D/calls" \
  && ok "an unrelated merge does not requeue a marker with sites" || fail "unrelated merge requeued: $out"

# 8. A commit touching the failing site's file → requeued.
printf 'fn f() { let _ = Ctx { a: 0 }; }\n' > "$PAPERCLIP_PROJECT/src/site.rs"; g commit -q -am "fix site"
g update-ref refs/remotes/origin/main HEAD
out="$(bash "$R")"
case "$out" in *"requeued T-1"*"touches src/site.rs"*) ok "a commit on the failing file requeues";; *) fail "site touch did not requeue: $out";; esac

# 9. A commit changing a line naming a quoted identifier, in another file → requeued.
reset
g reset -q --hard "$B"
printf 'struct Ctx { a: i16, attack_total: i16 }\n' > "$PAPERCLIP_PROJECT/src/def.rs"; g commit -q -am "add field"
g update-ref refs/remotes/origin/main HEAD
printf '%s\nT-1\nsrc/site.rs:1 E0063 missing field `attack_total` in initializer of `Ctx`\n' "$B" > "$V/T-1.base-red"
out="$(bash "$R")"
case "$out" in *"requeued T-1"*"naming \`attack_total\`"*) ok "a fix on the definition side requeues";; *) fail "identifier touch did not requeue: $out";; esac

# 10. A pending record left by a killed sweep, verify still unassigned → re-assigned.
reset
printf '%s\nT-1\nsrc/site.rs:1 E0063 x\n' "$B" > "$V/T-1.base-red"
echo "u1 arch V-1" > "$V/T-1.requeue-pending"
echo '{"identifier":"V-1","id":"u1","status":"todo","assigneeAgentId":null}' > "$D/issues.json"
out="$(bash "$R")"
case "$(grep PATCH "$D/calls" | sed -n 1p)" in *"/issues/u1 "*'"assigneeAgentId":"arch"'*) ok "a cut-off toggle is finished";; *) fail "cut-off toggle not finished: $(cat "$D/calls")";; esac
[ ! -e "$V/T-1.requeue-pending" ] && [ ! -e "$V/T-1.base-red" ] && ok "pending record and marker cleared once finished" \
  || fail "pending record or marker survived"

# 11. A pending record whose verify was re-assigned meanwhile → cleared, not patched.
reset
echo "u1 arch V-1" > "$V/T-1.requeue-pending"
echo '{"identifier":"V-1","id":"u1","status":"in_review","assigneeAgentId":"arch"}' > "$D/issues.json"
bash "$R" >/dev/null
[ ! -e "$V/T-1.requeue-pending" ] && ! grep -q PATCH "$D/calls" \
  && ok "an already re-assigned verify is left alone" || fail "re-assigned verify was patched"

# 12. A second sweep while one holds the lock → skips without touching anything.
reset
g update-ref refs/remotes/origin/main "$NEW"
printf '%s\nV-1\n' "$OLD" > "$V/T-1.base-red"; echo 1 > "$V/T-1.exit"
echo '[{"identifier":"V-1","id":"u1","status":"blocked","assigneeAgentId":"arch"}]' > "$D/issues.json"
out="$(flock "$V/.requeue-base-red.lock" bash "$R")"
case "$out" in *"skipped"*) ok "a concurrent sweep backs off the lock";; *) fail "no back-off: $out";; esac
[ -e "$V/T-1.base-red" ] && ! grep -q PATCH "$D/calls" && ok "the backed-off sweep changed nothing" || fail "backed-off sweep acted"

# 5. --dry-run changes nothing.
reset
printf '%s\n' "$OLD" > "$V/T-1.base-red"; echo 1 > "$V/T-1.exit"
bash "$R" --dry-run >/dev/null
[ -f "$V/T-1.exit" ] && [ -f "$V/T-1.base-red" ] && ! grep -q PATCH "$D/calls" \
  && ok "--dry-run is read-only" || fail "--dry-run modified state"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
