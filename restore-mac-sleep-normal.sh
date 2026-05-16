#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended for macOS only." >&2
  exit 1
fi

PID_FILE="${TMPDIR:-/tmp}/keep-mac-awake-until-battery-empty.pid"
KEEP_AWAKE_SCRIPT_NAME="keep-mac-awake-until-battery-empty.sh"
INCLUDE_ORPHAN_CAFFEINATE=0

if [[ "${1:-}" == "--include-orphan-caffeinate" ]]; then
  INCLUDE_ORPHAN_CAFFEINATE=1
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0 [--include-orphan-caffeinate]"
  echo
  echo "Stops the keep-awake script and restores normal macOS idle sleep behavior."
  echo "--include-orphan-caffeinate also stops exact orphan processes running: caffeinate -dims"
  exit 0
elif [[ -n "${1:-}" ]]; then
  echo "Unknown argument: $1" >&2
  echo "Usage: $0 [--include-orphan-caffeinate]" >&2
  exit 2
fi

read_pid_value() {
  local key="$1"
  if [[ -f "$PID_FILE" ]]; then
    awk -F= -v key="$key" '$1 == key && $2 ~ /^[0-9]+$/ { print $2; exit }' "$PID_FILE"
  fi
}

stop_pid() {
  local pid="$1"
  local label="$2"

  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ || "$pid" == "$$" ]]; then
    return 1
  fi

  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "Stopping $label (PID $pid)..."
    kill "$pid" >/dev/null 2>&1 || true
    return 0
  fi

  return 1
}

stopped_any=0

KEEP_AWAKE_PID="$(read_pid_value KEEP_AWAKE_PID || true)"
CAFFEINATE_PID="$(read_pid_value CAFFEINATE_PID || true)"

if stop_pid "$KEEP_AWAKE_PID" "keep-awake script"; then
  stopped_any=1
  sleep 1
fi

if [[ -z "$KEEP_AWAKE_PID" ]]; then
  for pid in $(pgrep -f "$KEEP_AWAKE_SCRIPT_NAME" 2>/dev/null || true); do
    if stop_pid "$pid" "keep-awake script"; then
      stopped_any=1
    fi
  done
  sleep 1
fi

if stop_pid "$CAFFEINATE_PID" "tracked caffeinate process"; then
  stopped_any=1
fi

if [[ "$INCLUDE_ORPHAN_CAFFEINATE" -eq 1 ]]; then
  for pid in $(pgrep -x caffeinate 2>/dev/null || true); do
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == "caffeinate -dims" || "$command_line" == "/usr/bin/caffeinate -dims" ]]; then
      if stop_pid "$pid" "orphan caffeinate -dims process"; then
        stopped_any=1
      fi
    fi
  done
fi

if [[ -f "$PID_FILE" ]]; then
  rm -f "$PID_FILE"
fi

if [[ "$stopped_any" -eq 1 ]]; then
  echo "Normal macOS idle sleep behavior has been restored."
else
  echo "No keep-awake process from this script was running."
  echo "Normal macOS idle sleep behavior is already in effect unless another app is preventing sleep."
fi
