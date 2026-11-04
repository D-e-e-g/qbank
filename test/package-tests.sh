#!/usr/bin/env bash
# Runs `swift test` on this Mac in every local Swift package under Packages/,
# so each package declares a .macOS platform next to .iOS(.v18). With no
# packages yet, this passes.
#
# usage: test/package-tests.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -gt 0 ]; then
  sed -n '6p' "$0" | sed 's/^# //' >&2
  exit 64
fi

found=0
failed=()
for manifest in Packages/*/Package.swift; do
  [ -f "$manifest" ] || continue
  package="$(dirname "$manifest")"
  found=$((found + 1))
  echo "::group::swift test in $package"
  if swift test --package-path "$package"; then
    echo "::endgroup::"
    echo "ok: $package"
  else
    echo "::endgroup::"
    echo "FAIL: $package" >&2
    failed+=("$package")
  fi
done

if [ "$found" -eq 0 ]; then
  echo "No packages to test."
fi
if [ ${#failed[@]} -gt 0 ]; then
  echo "swift test failed in: ${failed[*]}" >&2
  exit 1
fi
