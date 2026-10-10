#!/usr/bin/env bash
# Read or delete a Claude Code cloud session through the sessions API, with the
# operator's own login. Neither `claude` nor the agent tools offer a delete.
#
# Usage:  cloud-session.sh GET|DELETE <session_id>
#
# The id is the `session_…` part of the URL `claude --cloud` prints (also
# recorded as `<task>.cloud.session` in the verify cache). GET first: deleting a
# running session kills its build mid-flight. Delete the session, not the
# evidence: a verify's verdict lives in its `cloud-verify/<task>/<sha>` ref and
# on the task, never only in the transcript; read the ref first, and delete it
# separately with `git push origin --delete cloud-verify/<task>/<sha>`.
set -euo pipefail

method="${1:?GET|DELETE}"; id="${2:?session id}"
case "$method" in GET|DELETE) ;; *) echo "usage: $0 GET|DELETE <session_id>" >&2; exit 2 ;; esac

token="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/.credentials.json')))['claudeAiOauth']['accessToken'])")"
org="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude.json')))['oauthAccount']['organizationUuid'])")"
curl -sS -X "$method" "https://api.anthropic.com/v1/sessions/$id" \
  -H "Authorization: Bearer $token" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: ccr-byoc-2025-07-29" \
  -H "x-organization-uuid: $org"
echo
