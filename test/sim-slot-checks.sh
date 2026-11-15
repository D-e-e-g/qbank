#!/usr/bin/env bash
# Checks for the simulator slot (test/sim-slot.sh, taken by test/sim.sh).
#
# Run by test/release-checks.sh. Credential-free and simulator-free: the slot is
# a temporary lock file chosen through QB_SIM_SLOT_LOCK, and test/sim.sh runs
# against a fake xcrun. The checks that need macOS's lockf skip elsewhere.
# shellcheck disable=SC2016 # the inner shell programs are single-quoted on purpose
set -u

cd "$(dirname "$0")/.." || exit 1

FAILURES=0
fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}
pass() {
  echo "ok: $1"
}

work="$(mktemp -d "${TMPDIR:-/tmp}/qbank-sim-slot-check.XXXXXX")" || exit 1
# shellcheck disable=SC2317,SC2329 # invoked by the traps
cleanup() {
  [ -z "${holder_pid:-}" ] || kill "$holder_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Waits up to 10 seconds for a file to exist.
wait_for() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$1" ]
}

# A GitHub Actions run takes no slot, so a lock path that cannot exist is fine.
ci_out="$(GITHUB_ACTIONS=true QB_SIM_SLOT_LOCK=/nonexistent-qbank-dir/x/lock ./test/sim-slot.sh sh -c 'echo ran' 2>&1)"
if [ "$ci_out" = "ran" ]; then
  pass "sim-slot.sh skips the slot under GitHub Actions"
else
  fail "sim-slot.sh skips the slot under GitHub Actions: $ci_out"
fi

if ./test/sim-slot.sh >/dev/null 2>&1; then
  fail "sim-slot.sh refuses to run without a command"
else
  pass "sim-slot.sh refuses to run without a command"
fi

if [ ! -x /usr/bin/lockf ]; then
  echo "skip: no /usr/bin/lockf here, so the slot-holding checks run on macOS only"
else
  # These checks are about the slot, so they must not take the CI path.
  unset GITHUB_ACTIONS
  lock="$work/state/sim-slot.lock"
  export QB_SIM_SLOT_LOCK="$lock"

  status=0
  ./test/sim-slot.sh sh -c 'exit 7' >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 7 ]; then
    pass "sim-slot.sh creates the lock directory and keeps the command's exit status"
  else
    fail "sim-slot.sh creates the lock directory and keeps the command's exit status (got $status)"
  fi

  # A first holder keeps the slot until released; a second run must wait.
  /usr/bin/lockf -s "$lock" sh -c 'touch "$1"; while [ ! -e "$2" ]; do sleep 0.1; done' sh "$work/held" "$work/release" &
  holder_pid=$!
  if ! wait_for "$work/held"; then
    fail "the first holder takes the slot"
  else
    ./test/sim-slot.sh sh -c 'touch "$1"' sh "$work/second-ran" >"$work/second.out" 2>&1 &
    second_pid=$!
    sleep 1
    if [ -e "$work/second-ran" ]; then
      fail "a second run waits while the first holds the slot"
    else
      pass "a second run waits while the first holds the slot"
    fi
    if grep -q 'waiting for the simulator slot' "$work/second.out"; then
      pass "a waiting run says it is waiting for the simulator slot"
    else
      fail "a waiting run says it is waiting for the simulator slot"
    fi
    touch "$work/release"
    if wait_for "$work/second-ran"; then
      pass "the second run proceeds once the first releases the slot"
    else
      fail "the second run proceeds once the first releases the slot"
    fi
    wait "$second_pid" 2>/dev/null
  fi
  wait "$holder_pid" 2>/dev/null
  holder_pid=""

  # test/sim.sh against a fake xcrun: it takes the slot before it creates or
  # boots a device, holds it until the device is deleted, and boots one device.
  mkdir "$work/bin"
  cat >"$work/bin/xcrun" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG"
case "$*" in
  "simctl list devices --json") echo '{"devices":{}}' ;;
  "simctl list runtimes --json")
    echo '{"runtimes":[{"isAvailable":true,"platform":"iOS","identifier":"rt","version":"18.0","supportedDeviceTypes":[{"name":"iPhone 17 Pro","identifier":"dt","productFamily":"iPhone"}]}]}'
    ;;
  "simctl create "*) echo FAKE-UDID ;;
  "simctl delete "*) [ -z "${FAKE_SLOT_CHECK:-}" ] || /usr/bin/lockf -s -t 0 "$QB_SIM_SLOT_LOCK" true || echo "slot-held-at-delete" >>"$FAKE_LOG" ;;
esac
exit 0
FAKE
  chmod +x "$work/bin/xcrun"
  export FAKE_LOG="$work/xcrun.log"
  : >"$FAKE_LOG"

  /usr/bin/lockf -s "$lock" sh -c 'touch "$1"; while [ ! -e "$2" ]; do sleep 0.1; done' sh "$work/held2" "$work/release2" &
  holder_pid=$!
  wait_for "$work/held2" || fail "the first holder takes the slot for sim.sh"
  PATH="$work/bin:$PATH" ./test/sim.sh -- sh -c 'echo "command-ran" >>"$1"' sh "$FAKE_LOG" >"$work/sim.out" 2>&1 &
  sim_pid=$!
  sleep 1
  if [ ! -s "$FAKE_LOG" ]; then
    pass "sim.sh touches no simulator while another run holds the slot"
  else
    fail "sim.sh touches no simulator while another run holds the slot: $(tr '\n' ';' <"$FAKE_LOG")"
  fi
  touch "$work/release2"
  wait "$sim_pid" 2>/dev/null
  wait "$holder_pid" 2>/dev/null
  holder_pid=""
  if grep -q '^command-ran$' "$FAKE_LOG"; then
    pass "sim.sh runs its command once it has the slot"
  else
    fail "sim.sh runs its command once it has the slot: $(cat "$work/sim.out")"
  fi
  creates="$(grep -c '^simctl create ' "$FAKE_LOG")"
  boots="$(grep -c '^simctl boot ' "$FAKE_LOG")"
  if [ "$creates" -eq 1 ] && [ "$boots" -eq 1 ]; then
    pass "a sim.sh run creates and boots one device"
  else
    fail "a sim.sh run creates and boots one device (created $creates, booted $boots)"
  fi

  # The slot is still held when the device is deleted.
  : >"$FAKE_LOG"
  FAKE_SLOT_CHECK=1 PATH="$work/bin:$PATH" ./test/sim.sh -- true >/dev/null 2>&1
  if grep -q '^slot-held-at-delete$' "$FAKE_LOG"; then
    pass "sim.sh holds the slot until the device is deleted"
  else
    fail "sim.sh holds the slot until the device is deleted: $(tr '\n' ';' <"$FAKE_LOG")"
  fi
  unset QB_SIM_SLOT_LOCK FAKE_LOG
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES sim-slot check(s) failed." >&2
  exit 1
fi
