#!/usr/bin/env bash
# Runs only the named tests on one run-scoped simulator, for retrying a test
# that failed in CI without another hour of the full suite. docs/testing.md has
# the retry rule, and how to run this on the MacBook Pro 14.
#
# usage: test/only-testing.sh [--check] [--device iphone|ipad] [TEST_ID...]
#
# A TEST_ID is Target/Class or Target/Class/test for the QBankTests or
# QBankUITests target, for example QBankUITests/StudyUITests/testCoursePage. A
# Swift Testing function keeps its parentheses, as in QBankTests/Suite/test().
# With no TEST_ID the names come from the ONLY_TESTING environment variable,
# separated by whitespace. At most 10 names run at once. --check only validates
# them and prints them, and needs no Mac.
#
# It fails unless at least as many tests passed as names were given, so a name
# that matches nothing, or a test that skips itself on this device, never looks
# like a pass. The result bundle is kept only on failure: TestResults-named.xcresult.
#
# Compatible with the bash 3.2 that ships with macOS.
set -euo pipefail
export LC_ALL=C

cd "$(dirname "$0")/.."

MAX_TESTS=10
RESULT_BUNDLE=TestResults-named.xcresult
NAME='[A-Za-z_][A-Za-z0-9_]*'
TEST_ID="^(QBankTests|QBankUITests)(/$NAME){1,3}(\\(($NAME:)*\\))?\$"

check_only=0
device=iphone

usage() {
  sed -n '6p' "$0" | sed 's/^# //' >&2
  exit 64
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check)
      check_only=1
      shift
      ;;
    --device)
      [ $# -ge 2 ] || usage
      device="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

case "$device" in
  iphone) devices=(--device "iPhone 17 Pro" --device "iPhone 17") ;;
  ipad) devices=(--device "iPad Pro 13-inch (M5)" --device "iPad Pro 13-inch (M4)") ;;
  *)
    echo "only-testing.sh: --device must be iphone or ipad" >&2
    exit 64
    ;;
esac

# Split with globbing off: the names are untrusted until they pass the pattern.
if [ $# -eq 0 ]; then
  set -f
  # shellcheck disable=SC2086 # the split on whitespace is the format
  set -- ${ONLY_TESTING:-}
  set +f
fi
[ $# -gt 0 ] || {
  echo "only-testing.sh: no test names given" >&2
  exit 64
}
[ $# -le "$MAX_TESTS" ] || {
  echo "only-testing.sh: $# test names given, at most $MAX_TESTS run at once" >&2
  exit 64
}

only_testing=()
for test_id in "$@"; do
  if ! [[ "$test_id" =~ $TEST_ID ]]; then
    # %q so a hostile name cannot write workflow commands into the log.
    printf 'only-testing.sh: not a test name: %q\n' "$test_id" >&2
    exit 64
  fi
  only_testing+=("-only-testing:$test_id")
done

if [ "$check_only" -eq 1 ]; then
  printf '%s\n' "$@"
  exit 0
fi

rm -rf "$RESULT_BUNDLE"
./test/sim.sh "${devices[@]}" --timeout 1800 -- \
  xcodebuild test \
    -project QBank.xcodeproj \
    -scheme QBank \
    -configuration Debug \
    -destination "platform=iOS Simulator,id={{UDID}}" \
    -derivedDataPath "${DERIVED_DATA_PATH:-.build/DerivedData}" \
    -collect-test-diagnostics never \
    -resultBundlePath "$RESULT_BUNDLE" \
    "${only_testing[@]}"

xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json | python3 -c '
import json, sys
wanted = int(sys.argv[1])
summary = json.load(sys.stdin)
passed, failed, skipped = (summary[key] for key in ("passedTests", "failedTests", "skippedTests"))
print("only-testing.sh: %d passed, %d failed, %d skipped, for %d names" % (passed, failed, skipped, wanted))
if failed or passed < wanted:
    sys.exit("only-testing.sh: a name matched no test, or its test skipped itself on this device")
' "$#"
rm -rf "$RESULT_BUNDLE"
