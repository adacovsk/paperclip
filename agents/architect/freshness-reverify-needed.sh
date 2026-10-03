#!/usr/bin/env bash
# Decide whether a green verify must be re-run because origin/main moved under it.
#
# Usage:  freshness-reverify-needed.sh <verified-base> <new-base>
#         (run inside the task worktree)
# Exit:   0  re-verify: something a build or test reads changed between the bases
#         1  no re-verify: only documentation moved, so the green build still holds
#
# WHY. The Landing freshness gate compared the bases by SHA, so every advance of
# main cost a full re-verify and one of the two capped freshness slots. Most
# advances are the Planner merging its roadmap branch, which touches only
# Markdown under docs/ — about half of all merges to main. A green build was
# thrown away, rebuilt and usually overtaken again by the next roadmap merge, so
# verified branches queued behind each other instead of landing.
#
# FAIL CLOSED. Anything not provably documentation re-verifies: an unknown path,
# an unreadable old base (a force-pushed or garbage-collected SHA), or a git
# error. Wrongly skipping a re-verify can land an untested interaction; wrongly
# running one costs a build. Widen DOC_ONLY only for paths no build can read —
# check the project for include_str!/include_bytes! of a path before adding it.
set -u

OLD="${1:?usage: freshness-reverify-needed.sh <verified-base> <new-base>}"
NEW="${2:?usage: freshness-reverify-needed.sh <verified-base> <new-base>}"

changed=$(git diff --name-only "$OLD" "$NEW" 2>/dev/null) || exit 0

while IFS= read -r path; do
  [ -z "$path" ] && continue
  # The roadmap baseline is exempt by exact path, not as `scripts/*`: the
  # Planner rewrites it on almost every roadmap merge, so without it this check
  # misses most of what it exists for. Only the Python roadmap guards read it.
  # Every other file under scripts/ stays a build input, because cargo tests
  # read files there.
  case "$path" in
    docs/*|*.md|scripts/roadmap_section_baseline.txt) ;;
    *) exit 0 ;;
  esac
done <<< "$changed"
exit 1
