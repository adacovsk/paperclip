#!/usr/bin/env bash
# A daemonizing child must not inherit the lock fds.
#
# An flock lives as long as any fd on its open file description stays open, in
# any process. Cargo cold-starts the sccache server from under a slot whenever
# the server is not already up, and that daemon detaches and stays resident — so
# an inherited fd 9 holds the slot for the life of the daemon and capacity drops
# by one permanently. `reap_escaped_orphans` matches rustc and cargo only and
# cannot clear it.
#
# The build here stands in for cargo: it forks a child that outlives it and
# holds whatever fds it was given. The assertion is that the slot is reacquirable
# once the build returns, while the daemon is still alive.
set -u
SEM="$(cd "$(dirname "$0")" && pwd)/cargo-sem.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"; [ -n "${DAEMON:-}" ] && kill "$DAEMON" 2>/dev/null' EXIT
mkdir -p "$DIR/wt"

# Stand-in for `cargo` cold-starting sccache: detach a child that sleeps well
# past the end of this test, inheriting every fd it is handed.
cat > "$DIR/fake-cargo.sh" <<'INNER'
#!/usr/bin/env bash
setsid sleep 300 </dev/null >/dev/null 2>&1 &
echo "$!" > "$FAKE_DAEMON_PIDFILE"
exit 0
INNER
chmod +x "$DIR/fake-cargo.sh"

export CARGO_SEM_DIR="$DIR" CARGO_SEM_SLOTS=1 CARGO_SEM_POLL=0.05 \
       FAKE_DAEMON_PIDFILE="$DIR/daemon.pid"
( cd "$DIR/wt" && "$SEM" "$DIR/fake-cargo.sh" ) >/dev/null 2>&1
DAEMON="$(cat "$DIR/daemon.pid" 2>/dev/null)"

if [ -z "$DAEMON" ] || ! kill -0 "$DAEMON" 2>/dev/null; then
  echo "FAIL: stand-in daemon did not survive the build (test is not exercising the bug)"
  echo "RESULT: FAIL"; exit 1
fi

# The daemon is alive. If it inherited fd 9, slot 1 is still flocked.
if ( exec 9>"$DIR/cargo-slot-1.lock"; flock -n 9; ) 2>/dev/null; then
  echo "slot reacquired while the daemon is alive (pid $DAEMON)"
  echo "RESULT: PASS"
else
  echo "FAIL: slot still held — a detached child inherited the lock fd"
  echo "RESULT: FAIL"; exit 1
fi
