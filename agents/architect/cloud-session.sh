#!/usr/bin/env bash
# Read, list or delete Claude Code cloud sessions through the sessions API, with
# the operator's own login. Neither `claude` nor the agent tools offer a delete.
#
# Usage:  cloud-session.sh GET|DELETE|EVENTS <session_id>
#         cloud-session.sh LIST            # every session, all pages, one JSON array
#
# EVENTS reads the session's event log, which is the only place a sandbox that
# never came up says so: the session itself still reads as idle.
#
# The id is the `session_…` part of the URL `claude --cloud` prints (also
# recorded as `<task>.cloud.session` in the verify cache). GET first: deleting a
# running session kills its build mid-flight. Delete the session, not the
# evidence: a verify's verdict lives in its `cloud-verify/<task>/<sha>` ref and
# on the task, never only in the transcript; read the ref first, and delete it
# separately with `git push origin --delete cloud-verify/<task>/<sha>`.
set -euo pipefail

method="${1:?GET|DELETE|EVENTS|LIST}"
case "$method" in
  GET|DELETE) path="${2:?session id}" ;;
  EVENTS) method=GET; path="${2:?session id}/events?limit=1000" ;;
  LIST) ;;
  *) echo "usage: $0 GET|DELETE|EVENTS <session_id> | LIST" >&2; exit 2 ;;
esac

token="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/.credentials.json')))['claudeAiOauth']['accessToken'])")"
org="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude.json')))['oauthAccount']['organizationUuid'])")"
api() {
  curl -sS --fail-with-body -X "$1" "https://api.anthropic.com/v1/sessions$2" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: ccr-byoc-2025-07-29" \
    -H "x-organization-uuid: $org"
}

if [ "$method" != LIST ]; then
  api "$method" "/$path"
  echo
  exit 0
fi

# Pages of 200, chained by `after_id`; a failed page fails the whole listing, so a
# caller never mistakes a partial list for every session there is.
after=""
pages="$(mktemp)"; trap 'rm -f "$pages"' EXIT
while :; do
  page="$(api GET "${after:+?after_id=$after}")"
  printf '%s\n' "$page" >> "$pages"
  read -r more after < <(printf '%s' "$page" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("1" if d.get("has_more") else "0", d.get("last_id") or "")')
  [ "$more" = 1 ] && [ -n "$after" ] || break
done
python3 -c '
import json, sys
print(json.dumps([s for line in open(sys.argv[1]) if line.strip() for s in json.loads(line)["data"]]))' "$pages"
