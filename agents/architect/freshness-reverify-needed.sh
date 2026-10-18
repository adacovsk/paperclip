#!/usr/bin/env bash
# Decide whether a green verify must be re-run because origin/main moved under it.
#
# Usage:  freshness-reverify-needed.sh <verified-base> <new-base>
#         (run inside the task worktree)
# Exit:   0  re-verify: main's advance can interact with this branch
#         1  no re-verify: the green build still holds
#
# The decision is freshness_interaction.py's: a rebuild only where main's
# advance and the branch meet (a shared file, data directory, data reader or
# symbol, or a build-wide input). Its docstring has the rules and why. This
# wrapper keeps the interface every caller already uses, and fails closed when
# the decider cannot run at all.
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null || exit 0
python3 "$HERE/freshness_interaction.py" "${1:?verified base}" "${2:?new base}"
rc=$?
[ "$rc" -le 1 ] || exit 0
exit "$rc"
