#!/usr/bin/env bash
# Records the live QBankKit contract fixtures from a local qbank-server checkout.
#
# usage: test/record-contract.sh SERVER_CHECKOUT
#
# Reads SERVER_CHECKOUT and does not fetch or modify it. pin.json names that
# checkout's HEAD. Set QBANK_CONTRACT_SCRATCH to reuse a scratch tree; the
# default is a directory under ${TMPDIR:-/tmp}. Set QBANK_API_IMAGE when that
# commit has no image digest recorded in test/record-contract/main.ts.
set -euo pipefail

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

[ $# -eq 1 ] || usage
[ -d "$1" ] || usage

root=$(cd "$(dirname "$0")/.." && pwd)
server=$(cd "$1" && pwd)
commit=$(git -C "$server" rev-parse HEAD)
scratch=${QBANK_CONTRACT_SCRATCH:-${TMPDIR:-/tmp}/qbank-contract-record}
fixtures="$root/Packages/QBankKit/Tests/QBankKitTests/Fixtures"

mkdir -p "$scratch"
rsync -a --delete --exclude node_modules --exclude .git --exclude dist "$server/" "$scratch/"
if [ ! -d "$scratch/node_modules" ]; then
  ( cd "$scratch" && pnpm install --frozen-lockfile )
fi
rm -rf "$scratch/apps/api/scripts/record-contract"
cp -R "$root/test/record-contract" "$scratch/apps/api/scripts/record-contract"
(
  cd "$scratch/apps/api" || exit 1
  pnpm exec tsx scripts/record-contract/main.ts "$commit" "$fixtures" "$scratch/apps/api/openapi.json"
)
echo "contract fixtures pinned to $commit"
