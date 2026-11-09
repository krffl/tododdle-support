#!/bin/sh
# Copies the shared conformance cases into the Swift test resources.
# contract/cases/cases.json is the source of truth. A Swift test fails if the copy differs.
# Use --check to fail instead of copying (for CI).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
source="$root/contract/cases/cases.json"
copy="$root/swift/Tests/TododdleSupportTests/Resources/cases.json"
if [ "${1:-}" = "--check" ]; then
  if cmp -s "$source" "$copy"; then
    echo "Swift cases.json is up to date."
  else
    echo "Swift cases.json differs from contract/cases/cases.json. Run scripts/sync-swift-cases.sh." >&2
    exit 1
  fi
else
  cp "$source" "$copy"
  echo "Copied contract/cases/cases.json to the Swift test resources."
fi
