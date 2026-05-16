#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended for macOS only." >&2
  exit 1
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_SCRIPT="$BASE_DIR/monitor-mac-heat-apps.sh"
SERVER_SOURCE="$BASE_DIR/mac-heat-dashboard-server.py"

APP_SUPPORT_DIR="$HOME/Library/Application Support/mac-heat-app-monitor"
INSTALLED_SERVER="$APP_SUPPORT_DIR/mac-heat-dashboard-server.py"
DASHBOARD_PID_FILE="$APP_SUPPORT_DIR/dashboard.pid"
MONITOR_PID_FILE="${TMPDIR:-/tmp}/mac-heat-app-monitor.pid"

LOG_DIR="${MAC_HEAT_MONITOR_LOG_DIR:-$HOME/Library/Logs/mac-heat-app-monitor}"
SUMMARY_LOG="$LOG_DIR/summary.log"
ERROR_LOG="$LOG_DIR/error.log"
SAMPLES_TSV="$LOG_DIR/samples.tsv"
DASHBOARD_LOG="$LOG_DIR/dashboard.log"
DASHBOARD_ERROR_LOG="$LOG_DIR/dashboard-error.log"

LAUNCH_AGENT_LABEL="com.local.mac-heat-dashboard"
LAUNCH_AGENT_FILE="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"
MONITOR_LABEL="com.local.mac-heat-app-monitor"

HOST="127.0.0.1"
PORT="8765"
INTERVAL="30"
TOP_N="12"
START_MONITOR=1
OPEN_BROWSER=0
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

usage() {
  cat <<'USAGE'
Usage:
  ./mac-heat-dashboard.sh start [--interval SECONDS] [--top N] [--port PORT] [--open]
  ./mac-heat-dashboard.sh stop
  ./mac-heat-dashboard.sh stop-all
  ./mac-heat-dashboard.sh status
  ./mac-heat-dashboard.sh open
  ./mac-heat-dashboard.sh tail

What it does:
  Starts the background heat monitor and a local web dashboard at:
  http://127.0.0.1:8765

Logs:
  ~/Library/Logs/mac-heat-app-monitor/dashboard.log
  ~/Library/Logs/mac-heat-app-monitor/dashboard-error.log
USAGE
}

parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval)
        [[ $# -ge 2 ]] || { echo "--interval requires a value" >&2; exit 2; }
        INTERVAL="$2"
        shift 2
        ;;
      --top)
        [[ $# -ge 2 ]] || { echo "--top requires a value" >&2; exit 2; }
        TOP_N="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || { echo "--port requires a value" >&2; exit 2; }
        PORT="$2"
        shift 2
        ;;
      --host)
        [[ $# -ge 2 ]] || { echo "--host requires a value" >&2; exit 2; }
        HOST="$2"
        shift 2
        ;;
      --no-monitor)
        START_MONITOR=0
        shift
        ;;
      --open)
        OPEN_BROWSER=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "$INTERVAL" -lt 5 ]]; then
    echo "--interval must be an integer >= 5 seconds." >&2
    exit 2
  fi

  if ! [[ "$TOP_N" =~ ^[0-9]+$ ]] || [[ "$TOP_N" -lt 1 ]]; then
    echo "--top must be a positive integer." >&2
    exit 2
  fi

  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
    echo "--port must be an integer from 1 to 65535." >&2
    exit 2
  fi
}

read_pid() {
  [[ -f "$DASHBOARD_PID_FILE" ]] || return 1
  awk 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1; found = 1 } END { exit(found ? 0 : 1) }' "$DASHBOARD_PID_FILE"
}

is_running() {
  local pid="${1:-}"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1
}

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g" <<< "$1"
}

plist_string() {
  printf '    <string>%s</string>\n' "$(xml_escape "$1")"
}

launch_agent_domain() {
  printf 'gui/%s' "$(id -u)"
}

install_runtime_files() {
  if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
    echo "python3 was not found. Install Python 3 or set PYTHON_BIN=/path/to/python3." >&2
    exit 1
  fi

  if [[ ! -x "$MONITOR_SCRIPT" ]]; then
    echo "Monitor script is missing or not executable: $MONITOR_SCRIPT" >&2
    exit 1
  fi

  if [[ ! -f "$SERVER_SOURCE" ]]; then
    echo "Dashboard server is missing: $SERVER_SOURCE" >&2
    exit 1
  fi

  mkdir -p "$APP_SUPPORT_DIR" "$LOG_DIR" "$(dirname "$LAUNCH_AGENT_FILE")"
  cp "$SERVER_SOURCE" "$INSTALLED_SERVER"
  chmod 755 "$INSTALLED_SERVER"
  xattr -d com.apple.quarantine "$INSTALLED_SERVER" >/dev/null 2>&1 || true
}

write_launch_agent() {
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCH_AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
EOF
    plist_string "$PYTHON_BIN"
    plist_string "$INSTALLED_SERVER"
    plist_string "--host"
    plist_string "$HOST"
    plist_string "--port"
    plist_string "$PORT"
    plist_string "--samples"
    plist_string "$SAMPLES_TSV"
    plist_string "--summary-log"
    plist_string "$SUMMARY_LOG"
    plist_string "--error-log"
    plist_string "$ERROR_LOG"
    plist_string "--monitor-pid-file"
    plist_string "$MONITOR_PID_FILE"
    plist_string "--dashboard-pid-file"
    plist_string "$DASHBOARD_PID_FILE"
    plist_string "--monitor-label"
    plist_string "$MONITOR_LABEL"
    cat <<EOF
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$DASHBOARD_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$DASHBOARD_ERROR_LOG")</string>
</dict>
</plist>
EOF
  } > "$LAUNCH_AGENT_FILE"
}

dashboard_url() {
  printf 'http://%s:%s' "$HOST" "$PORT"
}

start_dashboard() {
  local domain pid

  install_runtime_files

  if [[ "$START_MONITOR" -eq 1 ]]; then
    "$MONITOR_SCRIPT" start --interval "$INTERVAL" --top "$TOP_N"
  fi

  write_launch_agent
  domain="$(launch_agent_domain)"
  launchctl bootout "$domain" "$LAUNCH_AGENT_FILE" >/dev/null 2>&1 || true
  launchctl bootstrap "$domain" "$LAUNCH_AGENT_FILE"
  launchctl kickstart -k "$domain/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  sleep 1

  pid="$(read_pid || true)"
  if is_running "$pid"; then
    echo "Started Mac heat dashboard with PID $pid."
  else
    echo "Requested dashboard start. Check the error log if it does not appear in status shortly."
  fi
  echo "Dashboard URL: $(dashboard_url)"
  echo "LaunchAgent: $LAUNCH_AGENT_FILE"
  echo "Dashboard log: $DASHBOARD_LOG"
  echo "Dashboard error log: $DASHBOARD_ERROR_LOG"

  if [[ "$OPEN_BROWSER" -eq 1 ]]; then
    open "$(dashboard_url)"
  fi
}

stop_dashboard() {
  local domain pid was_running=0

  pid="$(read_pid || true)"
  if is_running "$pid"; then
    was_running=1
  fi

  domain="$(launch_agent_domain)"
  launchctl bootout "$domain" "$LAUNCH_AGENT_FILE" >/dev/null 2>&1 || true

  if is_running "$pid"; then
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
  fi

  rm -f "$DASHBOARD_PID_FILE"
  if [[ "$was_running" -eq 1 ]]; then
    echo "Stopped Mac heat dashboard."
  else
    echo "Mac heat dashboard is not running."
  fi
}

stop_all() {
  stop_dashboard
  "$MONITOR_SCRIPT" stop
}

status_dashboard() {
  local domain pid

  domain="$(launch_agent_domain)"
  pid="$(read_pid || true)"

  if is_running "$pid"; then
    echo "Mac heat dashboard is running with PID $pid."
  else
    echo "Mac heat dashboard is not running."
  fi
  echo "Dashboard URL: $(dashboard_url)"
  echo "Dashboard log: $DASHBOARD_LOG"
  echo "Dashboard error log: $DASHBOARD_ERROR_LOG"
  echo "LaunchAgent: $LAUNCH_AGENT_FILE"

  if launchctl print "$domain/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1; then
    echo "LaunchAgent state: loaded"
  else
    echo "LaunchAgent state: not loaded"
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -fsS "$(dashboard_url)/health" >/dev/null 2>&1; then
      echo "HTTP health: ok"
    else
      echo "HTTP health: not responding"
    fi
  fi
}

tail_dashboard() {
  mkdir -p "$LOG_DIR"
  touch "$DASHBOARD_LOG" "$DASHBOARD_ERROR_LOG"
  tail -n 80 -f "$DASHBOARD_LOG" "$DASHBOARD_ERROR_LOG"
}

COMMAND="${1:-status}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$COMMAND" in
  start)
    parse_options "$@"
    start_dashboard
    ;;
  stop)
    parse_options "$@"
    stop_dashboard
    ;;
  stop-all)
    parse_options "$@"
    stop_all
    ;;
  status)
    parse_options "$@"
    status_dashboard
    ;;
  open)
    parse_options "$@"
    open "$(dashboard_url)"
    ;;
  tail)
    parse_options "$@"
    tail_dashboard
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage >&2
    exit 2
    ;;
esac
