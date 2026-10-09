#!/usr/bin/env bash
# Tests for requeue-base-red.sh.
#
# The load-bearing properties: a marker whose sha is still origin/main is left
# alone (re-running would only reproduce the red); a stale one has its result
# deleted BEFORE the task is re-dispatched; the re-dispatch toggles the assignee
# through null (the only thing that fires a wake); and a task that is no longer
# blocked is cleared but not touched.
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
export PAPERCLIP_COMPANY_ID=co
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

# 3. Stale marker, task no longer blocked → cleared, not patched.
reset
printf '%s\n' "$OLD" > "$V/T-1.base-red"; echo 1 > "$V/T-1.exit"
echo '[{"identifier":"T-1","id":"u2","status":"in_progress","assigneeAgentId":"arch"}]' > "$D/issues.json"
bash "$R" >/dev/null
[ ! -e "$V/T-1.exit" ] && ! grep -q PATCH "$D/calls" \
  && ok "non-blocked task cleared but not re-dispatched" || fail "non-blocked task was patched or not cleared"

# 4. Unknown task after a known one → no reuse of the previous marker's ids.
reset
printf '%s\nV-1\n' "$OLD" > "$V/A-1.base-red"; printf '%s\nV-9\n' "$OLD" > "$V/B-1.base-red"
echo '[{"identifier":"V-1","id":"u1","status":"blocked","assigneeAgentId":"arch"}]' > "$D/issues.json"
bash "$R" >/dev/null
[ "$(grep -c PATCH "$D/calls")" = 2 ] && ok "an unknown task does not reuse the previous lookup" \
  || fail "PATCH count $(grep -c PATCH "$D/calls"), expected 2"

# 5. --dry-run changes nothing.
reset
printf '%s\n' "$OLD" > "$V/T-1.base-red"; echo 1 > "$V/T-1.exit"
bash "$R" --dry-run >/dev/null
[ -f "$V/T-1.exit" ] && [ -f "$V/T-1.base-red" ] && ! grep -q PATCH "$D/calls" \
  && ok "--dry-run is read-only" || fail "--dry-run modified state"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
