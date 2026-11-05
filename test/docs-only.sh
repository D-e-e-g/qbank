#!/usr/bin/env bash
# Says whether a change is one that cannot affect the Mac build, from the list
# of changed paths on stdin, one per line. Exits 0 only when every path is on
# this allowlist and at least one path was given; anything else, including a
# path it has never heard of, exits 1 so the full build runs.
#
# usage: git diff --name-only --no-renames BASE HEAD | test/docs-only.sh
set -euo pipefail

if [ $# -gt 0 ]; then
  sed -n '7p' "$0" | sed 's/^# //' >&2
  exit 64
fi

found=0
while IFS= read -r path || [ -n "$path" ]; do
  found=1
  case "$path" in
    *..*) exit 1 ;;
    README.md | SECURITY.md | SUPPORT.md | AGENTS.md | CLAUDE.md) ;;
    docs/*) ;;
    *) exit 1 ;;
  esac
done
[ "$found" -eq 1 ]
