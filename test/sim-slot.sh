#!/usr/bin/env bash
# Runs one command while holding the simulator slot.
#
# usage: test/sim-slot.sh COMMAND [ARGS...]
#
# The development Mac has one simulator slot, shared by every app and every
# agent on it: two runs that boot simulators at once peg its CPU. The slot is
# the lock file ~/.local/state/sim-slot.lock, taken with macOS /usr/bin/lockf
# and held until COMMAND exits, so a second run waits instead of piling on.
# Another app's script takes the same file, which is why the path is fixed.
# test/sim.sh calls this before it creates a device; a build that boots no
# simulator needs no slot.
#
# A GitHub Actions run skips the slot: the self-hosted runner is another
# machine that already runs one job at a time, and it has no such directory.
# QB_SIM_SLOT_LOCK overrides the lock file for tests, never for real runs.
# QB_SIM_SLOT_SETTLED=1 is set for COMMAND so a nested script never waits on a
# slot its caller already holds.
#
# Compatible with the bash 3.2 that ships with macOS.
set -euo pipefail

[ $# -gt 0 ] || {
  sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

export QB_SIM_SLOT_SETTLED=1
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  exec "$@"
fi

lockf=/usr/bin/lockf
[ -x "$lockf" ] || {
  echo "sim-slot.sh: $lockf not found; the simulator slot needs macOS" >&2
  exit 69
}

lock="${QB_SIM_SLOT_LOCK:-${HOME:?}/.local/state/sim-slot.lock}"
mkdir -p "$(dirname "$lock")"

# lockf waits for the lock by default. Say so first, so a waiting run is not
# mistaken for a hang. The probe can lose a race; it only decides the message.
if ! "$lockf" -s -t 0 "$lock" true; then
  echo "sim-slot.sh: waiting for the simulator slot ($lock)" >&2
fi

# lockf does not pass signals on to COMMAND, so a run stopped with kill would
# carry on without the slot. Forward them to COMMAND, which sim.sh's own traps
# then clean up after. A background job starts with SIGINT ignored, which a
# shell cannot undo, so perl restores the default before it execs COMMAND.
# shellcheck disable=SC2016 # a perl program, not shell
"$lockf" -s "$lock" /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or exit 127' -- "$@" &
holder=$!
# shellcheck disable=SC2317,SC2329 # invoked by the signal traps
forward() {
  local child
  for child in $(pgrep -P "$holder" 2>/dev/null || true); do
    kill -s "$1" "$child" 2>/dev/null || true
  done
}
trap 'forward INT' INT
trap 'forward TERM' TERM
trap 'forward HUP' HUP
status=0
# A trapped signal ends wait early, so wait until the holder is really gone.
while kill -0 "$holder" 2>/dev/null; do
  wait "$holder" || status=$?
done
exit "$status"
