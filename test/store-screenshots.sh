#!/usr/bin/env bash
# Retakes the App Store screenshots in docs/app-store-screenshots/ by running
# StoreScreenshotsUITests on a 6.9-inch iPhone and a 13-inch iPad, one
# run-scoped simulator after the other through test/sim.sh, in light with a
# clean status bar. docs/app-store-screenshots/README.md says what they are.
#
# usage: test/store-screenshots.sh
#
# Nothing is replaced unless both devices pass. The pictures come only from the
# sample set the app ships with, on the fake server and store.
#
# Compatible with the bash 3.2 that ships with macOS.
set -euo pipefail

cd "$(dirname "$0")/.."

OUTPUT=docs/app-store-screenshots
# Apple's customary 9:41 on January 9. An iPad's status bar shows the date too,
# and over this app it names January 9 a Sunday whatever the year, so the year
# is one whose January 9 is a Sunday.
STATUS_TIME="2022-01-09T09:41:00.000"

usage() {
  sed -n '7p' "$0" | sed 's/^# //' >&2
  exit 64
}

# test/sim.sh runs this on the device it booted.
if [ "${1:-}" = --on-device ]; then
  [ $# -eq 3 ] || usage
  udid="$2"
  staging="$3"
  # An iPad that allows windows draws a resize handle in the app's corner, so it
  # is set to Full Screen Apps, which SpringBoard reads at boot. An iPhone
  # ignores both keys.
  xcrun simctl spawn "$udid" defaults write com.apple.springboard SBChamoisWindowingEnabled -bool false
  xcrun simctl spawn "$udid" defaults write com.apple.springboard SBMedusaMultitaskingEnabled -bool false
  xcrun simctl shutdown "$udid"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" >/dev/null
  xcrun simctl ui "$udid" appearance light
  offset="$(date -j -f '%Y-%m-%dT%H:%M:%S' "${STATUS_TIME%.*}" +%z)"
  xcrun simctl status_bar "$udid" override \
    --time "${STATUS_TIME}${offset:0:3}:${offset:3:2}" \
    --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName '' \
    --batteryState discharging --batteryLevel 100
  TEST_RUNNER_STORE_SCREENSHOTS_DIR="$staging" exec xcodebuild test \
    -project QBank.xcodeproj \
    -scheme QBank \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "${DERIVED_DATA_PATH:-.build/DerivedData}" \
    -collect-test-diagnostics never \
    -only-testing:QBankUITests/StoreScreenshotsUITests
fi
[ $# -eq 0 ] || usage

staging="$(mktemp -d "${TMPDIR:-/tmp}/qbank-store-screenshots.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

./test/sim.sh --device "iPhone 17 Pro Max" --device "iPhone 16 Pro Max" -- \
  "$0" --on-device "{{UDID}}" "$staging"
./test/sim.sh --device "iPad Pro 13-inch (M5)" --device "iPad Pro 13-inch (M4)" -- \
  "$0" --on-device "{{UDID}}" "$staging"

# Whole folders are replaced, so a screen the test no longer takes does not linger.
for folder in iphone-6.9 ipad-13 review; do
  [ -d "$staging/$folder" ] || {
    echo "store-screenshots.sh: the test wrote no $folder pictures" >&2
    exit 1
  }
done
mkdir -p "$OUTPUT"
for folder in iphone-6.9 ipad-13 review; do
  rm -rf "${OUTPUT:?}/$folder"
  cp -R "$staging/$folder" "$OUTPUT/$folder"
done
echo "store-screenshots.sh: wrote $OUTPUT; look at every picture before committing it"
