#!/usr/bin/env bash
# A leaked worktree lock must not strand a build forever.
#
# The per-worktree flock outlives its build whenever any process still holds an
# fd on it, and a waiter stuck behind such a lock looks alive, so nothing ever
# relaunches it. The wait is bounded: past CARGO_SEM_WT_WAIT the wrapper exits
# 75 without running the build, and names the processes holding the lock.
set -u
SEM="$(cd "$(dirname "$0")" && pwd)/cargo-sem.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"; [ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null' EXIT
mkdir -p "$DIR/wt"

# Stand-in for the leak: an unrelated process holding the worktree lock.
KEY="$(cd "$DIR/wt" && pwd -P | cksum | tr -d ' \t-')"
( exec 3>"$DIR/cargo-wt-$KEY.lock"; flock 3; exec sleep 60 ) &
HOLDER=$!
for _ in $(seq 50); do ( exec 3>"$DIR/cargo-wt-$KEY.lock"; ! flock -n 3 ) 2>/dev/null && break; sleep 0.05; done

cat > "$DIR/fake-cargo.sh" <<'INNER'
#!/usr/bin/env bash
touch "$BUILD_RAN"
INNER
chmod +x "$DIR/fake-cargo.sh"

export CARGO_SEM_DIR="$DIR" CARGO_SEM_SLOTS=1 CARGO_SEM_POLL=0.05 \
       CARGO_SEM_WT_WAIT=1 CARGO_SEM_REAP_ORPHANS=0 BUILD_RAN="$DIR/ran"
start=$(date +%s)
( cd "$DIR/wt" && "$SEM" "$DIR/fake-cargo.sh" ) 2>"$DIR/err" >/dev/null
rc=$?
elapsed=$(( $(date +%s) - start ))

fail=0
[ "$rc" -eq 75 ] || { echo "FAIL: exit $rc, expected 75"; fail=1; }
[ ! -e "$DIR/ran" ] || { echo "FAIL: the build ran despite never acquiring the worktree lock"; fail=1; }
[ "$elapsed" -le 10 ] || { echo "FAIL: took ${elapsed}s, the wait is not bounded"; fail=1; }
grep -q "pid=$HOLDER " "$DIR/err" || { echo "FAIL: the holder (pid $HOLDER) was not named:"; cat "$DIR/err"; fail=1; }

[ "$fail" -eq 0 ] && { echo "gave up with 75 after ${elapsed}s and named the holder"; echo "RESULT: PASS"; } || { echo "RESULT: FAIL"; exit 1; }
