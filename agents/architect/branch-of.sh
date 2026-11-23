# Sourced, not run: the branch and worktree a verify key names.
#
#   <id>        task/<id>, in $PAPERCLIP_PROJECT/.paperclip/worktrees/<id>
#   op-<slug>   op/<slug>, in whichever worktree of $PAPERCLIP_PROJECT has it
#               checked out (operator worktrees live outside .paperclip/)
#
# WHY. An operator session opens its PR from an `op/*` branch as a draft, and the
# build that marks a draft ready was reachable only from `task/*`: an op PR that
# nobody sent to the cloud lane by hand stayed a draft indefinitely, with nothing
# reporting it. One key scheme lets the same launch, landing and merge scripts
# carry an op branch, so there is still one way a build is launched.
#
# `op-` is safe as a prefix: task ids are Paperclip identifiers (`AA-123`), which
# never start with it. The verify state files are keyed `op-<slug>.*` already.

key_branch() {
  case "$1" in
    op-*) printf 'op/%s' "${1#op-}" ;;
    *) printf 'task/%s' "$1" ;;
  esac
}

# The verify key for a PR's head branch, or nothing for a branch no key names.
branch_key() {
  case "$1" in
    task/*) printf '%s' "${1#task/}" ;;
    op/*) printf 'op-%s' "${1#op/}" ;;
  esac
}

# Prints the worktree path, or nothing when no worktree has the branch.
key_worktree() {
  local branch
  case "$1" in
    op-*)
      branch="$(key_branch "$1")"
      git -C "${PAPERCLIP_PROJECT:?set PAPERCLIP_PROJECT}" worktree list --porcelain 2>/dev/null \
        | awk -v b="branch refs/heads/$branch" '/^worktree /{w=substr($0,10)} $0==b{print w; exit}' ;;
    *)
      [ -d "${PAPERCLIP_PROJECT:?set PAPERCLIP_PROJECT}/.paperclip/worktrees/$1" ] \
        && printf '%s' "$PAPERCLIP_PROJECT/.paperclip/worktrees/$1" ;;
  esac
}
