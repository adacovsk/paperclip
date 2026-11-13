#!/usr/bin/env bash
# Print the lines a diff adds that suppress a Rust lint or test.
#
# The project bans suppressing a warning or a test instead of fixing it. A green
# build cannot see the difference, because the suppression is what made it
# green, so every path that lands without a model reading the diff runs this:
# cloud-verify.sh on the VM's commits, local-landable.sh on the Worker's and
# Reviewer's.
#
# Usage:  suppressions.sh <from> <to>   (run inside the repository)
# Output: one added line per suppression, sorted and unique; nothing when clean
# Exit:   0 always; a git failure prints nothing, so callers that must fail
#         closed check the revs themselves
set -uo pipefail

git diff -U0 "${1:?from}" "${2:?to}" -- '*.rs' \
  | grep -E '^\+.*(#!?\[(allow|expect)\(|#\[ignore)' | grep -v '^+++' | sort -u
exit 0
