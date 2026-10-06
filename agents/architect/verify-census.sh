#!/usr/bin/env bash
# Which detached `verifyrun-AA-<n>` builds are alive.
#
#   verify-census.sh            print every live id, one per line
#   verify-census.sh AA-12738   exit 0 if that build is alive, 1 if not
#
# A script, not an inline snippet, because the snippet self-matches the moment a
# caller narrows it in the same command: `... | grep -x verifyrun-AA-12738` puts
# the id into the probing shell's argv, `ps` reads it back, and a build that does
# not exist reports live. An Architect did exactly that, then waited out a
# 15-minute sentinel poll for a build that was never launched. The ancestry of
# this process is excluded from the `ps` half, so no caller spelling can do that.
#
# Both halves stay: the systemd scope name carries the id for both launch forms
# (primary); `ps` covers a wrapper whose scope registration failed. `[0-9]+`, not
# `[0-9]*`, so the pattern cannot match zero digits against itself.
set -uo pipefail

ancestors=" "
pid=$$
while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
  ancestors+="$pid "
  pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || break
done

live=$(
  {
    systemctl --user list-units 'verifyrun-*' --no-legend --plain --state=running 2>/dev/null \
      | awk '{print $1}' | grep -oE 'verifyrun-AA-[0-9]+'
    ps -eo pid=,args= | while read -r p args; do
      case "$ancestors" in *" $p "*) continue ;; esac
      grep -oE 'verifyrun-AA-[0-9]+' <<<"$args"
    done
  } | sed 's/^verifyrun-//' | sort -u
)

if [ $# -eq 0 ]; then
  [ -n "$live" ] && printf '%s\n' "$live"
  exit 0
fi
grep -qx "$1" <<<"$live"
