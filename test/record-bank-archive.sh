#!/usr/bin/env bash
# Records the bank archive fixture from a local qbank-server checkout.
#
# usage: test/record-bank-archive.sh SERVER_CHECKOUT
#
# Reads SERVER_CHECKOUT and does not fetch or modify it. The checkout needs
# GET /api/me/bank (bank archive v1). Set QBANK_CONTRACT_SCRATCH to reuse a
# scratch tree; the default is a directory under ${TMPDIR:-/tmp}. Writes
# Packages/QBankKit/Tests/QBankKitTests/Fixtures/bank-archive/server-bank.json.
# A record is not byte-stable: times change from one run to the next.
set -euo pipefail

[ $# -eq 1 ] && [ -d "$1" ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }

root=$(cd "$(dirname "$0")/.." && pwd)
server=$(cd "$1" && pwd)
commit=$(git -C "$server" rev-parse HEAD)
scratch=${QBANK_CONTRACT_SCRATCH:-${TMPDIR:-/tmp}/qbank-bank-archive-record}
out="$root/Packages/QBankKit/Tests/QBankKitTests/Fixtures/bank-archive"

mkdir -p "$scratch" "$out"
rsync -a --delete --exclude node_modules --exclude .git --exclude dist "$server/" "$scratch/"
if [ ! -d "$scratch/node_modules" ]; then
  ( cd "$scratch" && pnpm install --frozen-lockfile )
fi
rm -rf "$scratch/apps/api/scripts/record-bank-archive" "$scratch/apps/api/scripts/record-contract"
cp -R "$root/test/record-bank-archive" "$scratch/apps/api/scripts/record-bank-archive"
cp -R "$root/test/record-contract" "$scratch/apps/api/scripts/record-contract"
( cd "$scratch/apps/api" && pnpm exec tsx scripts/record-bank-archive/main.ts "$commit" "$out/server-bank.json" )
echo "bank archive recorded from $commit"
