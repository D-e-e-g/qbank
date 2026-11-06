#!/usr/bin/env bash
# Runs one command against a fresh, run-scoped iOS simulator, then deletes it.
#
# usage: test/sim.sh [--device NAME]... [--timeout SECONDS] -- COMMAND [ARGS...]
#
# Every literal {{UDID}} in COMMAND and ARGS is replaced with the new device's
# UDID, for example:
#
#   test/sim.sh -- xcodebuild test -project QBank.xcodeproj -scheme QBank \
#     -destination 'platform=iOS Simulator,id={{UDID}}'
#
# The device uses the newest available iOS simulator runtime (of equal
# versions, the one with the most device types) and the first --device name
# that runtime supports (default order: iPhone 17 Pro, iPhone 17,
# iPhone 16 Pro, iPhone 16; otherwise the runtime's last listed device of the
# first name's family, iPhone or iPad). It is booted headlessly, and shut down
# and deleted on every exit path, along with any clones of it that parallel
# testing made. Devices left behind by an earlier run that was killed are reaped
# first.
# COMMAND is stopped after --timeout seconds (default 3600).
#
# Compatible with the bash 3.2 that ships with macOS.
set -euo pipefail

PREFIX="qbank-run"
timeout_seconds=3600
preferred=()

usage() {
  sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

while [ $# -gt 0 ]; do
  case "$1" in
    --device)
      [ $# -ge 2 ] || usage
      preferred+=("$2")
      shift 2
      ;;
    --timeout)
      [ $# -ge 2 ] || usage
      case "$2" in '' | *[!0-9]*) usage ;; esac
      timeout_seconds="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      ;;
  esac
done
[ $# -gt 0 ] || usage
if [ ${#preferred[@]} -eq 0 ]; then
  preferred=("iPhone 17 Pro" "iPhone 17" "iPhone 16 Pro" "iPhone 16")
fi

log() {
  echo "sim.sh: $*" >&2
}

# Runs "$@" and kills it with SIGALRM after $1 seconds (exit status 142).
run_with_timeout() {
  local seconds="$1"
  shift
  perl -e 'alarm shift @ARGV; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$seconds" "$@"
}

# Prints "<udid> <owner pid>" for this script's devices in a simctl device set.
# Device names are "$PREFIX-<pid>-<random>". xcodebuild's parallel test workers
# run on clones in the "testing" set, named "Clone <n> of <device name>"; it
# deletes them itself unless it is killed.
run_devices() {
  xcrun simctl --set "$1" list devices --json | PREFIX="$PREFIX" python3 -c '
import json, os, re, sys
pattern = re.compile(r"^(?:Clone \d+ of )?" + re.escape(os.environ["PREFIX"]) + r"-(\d+)-\d+$")
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        match = pattern.match(device["name"])
        if match:
            print(device["udid"], match.group(1))
'
}

# Deletes devices from earlier runs whose owning process no longer exists.
reap_orphans() {
  local device_set udid pid
  for device_set in default testing; do
    while IFS=' ' read -r udid pid; do
      [ -n "$udid" ] || continue
      if ! kill -0 "$pid" 2>/dev/null; then
        log "reaping orphaned simulator $udid (owner pid $pid is gone)"
        xcrun simctl --set "$device_set" shutdown "$udid" >/dev/null 2>&1 || true
        xcrun simctl --set "$device_set" delete "$udid" >/dev/null 2>&1 || true
      fi
    done <<EOF_ORPHANS
$(run_devices "$device_set")
EOF_ORPHANS
  done
}

# Deletes the clones of this run's device that a killed xcodebuild left behind.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
delete_own_clones() {
  local udid pid
  while IFS=' ' read -r udid pid; do
    [ "$pid" = "$$" ] || continue
    log "deleting simulator clone $udid"
    xcrun simctl --set testing shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl --set testing delete "$udid" >/dev/null 2>&1 || log "warning: could not delete simulator clone $udid"
  done <<EOF_CLONES
$(run_devices testing)
EOF_CLONES
}

# Prints "<runtime id>\t<runtime version>\t<device type id>\t<device type name>".
choose_device() {
  xcrun simctl list runtimes --json | python3 -c '
import json, sys
preferred = sys.argv[1:]
runtimes = [
    r for r in json.load(sys.stdin)["runtimes"]
    if r.get("isAvailable")
    and (r.get("platform") == "iOS" or ".SimRuntime.iOS-" in r.get("identifier", ""))
]
if not runtimes:
    sys.exit("no available iOS simulator runtime; install one with: xcodebuild -downloadPlatform iOS")
# Of equal versions, the runtime with the most device types: Xcode can also
# hold a runtime made for one new device, with the same version number.
runtime = max(runtimes, key=lambda r: (
    tuple(int(p) for p in r["version"].split(".")),
    len(r.get("supportedDeviceTypes", [])),
))
types = runtime.get("supportedDeviceTypes", [])
by_name = {t["name"]: t for t in types}
chosen = next((by_name[n] for n in preferred if n in by_name), None)
if chosen is None:
    family = "iPad" if preferred[0].startswith("iPad") else "iPhone"
    devices = [t for t in types if t.get("productFamily") == family]
    if not devices:
        sys.exit("iOS runtime %s supports no %s device type" % (runtime["version"], family))
    chosen = devices[-1]
print("\t".join([runtime["identifier"], runtime["version"], chosen["identifier"], chosen["name"]]))
' "${preferred[@]}"
}

udid=""
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
  local status=$?
  if [ -n "$udid" ]; then
    delete_own_clones
    log "deleting simulator $udid"
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" >/dev/null 2>&1 || log "warning: could not delete simulator $udid"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

reap_orphans

choice="$(choose_device)"
IFS="$(printf '\t')" read -r runtime_id runtime_version type_id type_name <<EOF_CHOICE
$choice
EOF_CHOICE

udid="$(xcrun simctl create "$PREFIX-$$-$RANDOM" "$type_id" "$runtime_id")"
log "created $type_name on iOS $runtime_version: $udid"

xcrun simctl boot "$udid"
if ! run_with_timeout 600 xcrun simctl bootstatus "$udid" >/dev/null; then
  log "simulator $udid did not finish booting within 600 seconds"
  exit 1
fi
log "booted $udid"

command=()
for arg in "$@"; do
  command+=("${arg//\{\{UDID\}\}/$udid}")
done

set +e
run_with_timeout "$timeout_seconds" "${command[@]}"
status=$?
set -e
if [ "$status" -eq 142 ]; then
  log "command timed out after $timeout_seconds seconds"
fi
exit "$status"
