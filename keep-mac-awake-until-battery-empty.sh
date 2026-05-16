#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended for macOS only." >&2
  exit 1
fi

if ! command -v caffeinate >/dev/null 2>&1; then
  echo "caffeinate was not found. This script requires macOS caffeinate." >&2
  exit 1
fi

PID_FILE="${TMPDIR:-/tmp}/keep-mac-awake-until-battery-empty.pid"

read_pid_value() {
  local key="$1"
  if [[ -f "$PID_FILE" ]]; then
    awk -F= -v key="$key" '$1 == key && $2 ~ /^[0-9]+$/ { print $2; exit }' "$PID_FILE"
  fi
}

EXISTING_PID="$(read_pid_value KEEP_AWAKE_PID || true)"
if [[ -n "$EXISTING_PID" ]] && kill -0 "$EXISTING_PID" >/dev/null 2>&1; then
  echo "Keep-awake script is already running with PID $EXISTING_PID."
  echo "Run restore-mac-sleep-normal.sh first if you want to restart it."
  exit 0
fi

echo "Keeping this Mac awake until the script is stopped or the battery is exhausted."
echo "Stop it with Ctrl-C, or run: restore-mac-sleep-normal.sh"
echo
echo "Note: macOS may still sleep/shut down for lid close, critical battery, thermal, or hardware protection events."
echo

cleanup() {
  if [[ -n "${CAFFEINATE_PID:-}" ]] && kill -0 "$CAFFEINATE_PID" >/dev/null 2>&1; then
    kill "$CAFFEINATE_PID" >/dev/null 2>&1 || true
  fi

  if [[ "$(read_pid_value KEEP_AWAKE_PID || true)" == "$$" ]]; then
    rm -f "$PID_FILE"
  fi
}

trap cleanup EXIT INT TERM

# -d prevents display sleep.
# -i prevents idle system sleep.
# -m prevents disk sleep.
# -s requests system sleep prevention while on AC power; macOS may ignore it on battery.
caffeinate -dims &
CAFFEINATE_PID=$!

umask 077
{
  printf 'KEEP_AWAKE_PID=%s\n' "$$"
  printf 'CAFFEINATE_PID=%s\n' "$CAFFEINATE_PID"
} > "$PID_FILE"

wait "$CAFFEINATE_PID"
