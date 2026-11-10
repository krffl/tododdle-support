#!/usr/bin/env bash
# Runs the Godot addon tests headless against the local mock server.
#
#   godot/run-tests.sh [name-filter]
#
# Set GODOT to the Godot 4 binary if `godot` is not on PATH. Needs Node.js 20 or later.
set -euo pipefail

cd "$(dirname "$0")"

GODOT="${GODOT:-godot}"
if ! command -v "$GODOT" >/dev/null 2>&1; then
  mac_godot="/Applications/Godot.app/Contents/MacOS/Godot"
  if [ -x "$mac_godot" ]; then
    GODOT="$mac_godot"
  else
    echo "Godot not found. Set GODOT to the Godot 4 binary." >&2
    exit 2
  fi
fi

work="$(mktemp -d)"
mock_pid=""
cleanup() {
  if [ -n "$mock_pid" ]; then kill "$mock_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

node tests/mock_server.mjs >"$work/port" 2>"$work/mock.log" &
mock_pid=$!
for _ in $(seq 1 100); do
  if [ -s "$work/port" ]; then break; fi
  sleep 0.05
done
if [ ! -s "$work/port" ]; then
  echo "The mock server did not start:" >&2
  cat "$work/mock.log" >&2
  exit 2
fi
export TODODDLE_MOCK_URL="http://127.0.0.1:$(head -n 1 "$work/port")"

# Build the class cache (.godot/) so the addon's class_name types resolve.
"$GODOT" --headless --path . --import >"$work/import.log" 2>&1 || {
  cat "$work/import.log" >&2
  exit 2
}

set +e
"$GODOT" --headless --path . --script res://tests/run_tests.gd -- "$@" 2>&1 | tee "$work/test.log"
status=${PIPESTATUS[0]}
set -e

# Script errors do not always fail a run, so treat them as failures.
if grep -E "SCRIPT ERROR|Parse Error|Compile Error|^ERROR:" "$work/test.log" >/dev/null; then
  echo "Script errors were printed during the run." >&2
  exit 1
fi
exit "$status"
