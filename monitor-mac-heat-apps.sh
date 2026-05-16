#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended for macOS only." >&2
  exit 1
fi

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PID_FILE="${TMPDIR:-/tmp}/mac-heat-app-monitor.pid"
APP_SUPPORT_DIR="$HOME/Library/Application Support/mac-heat-app-monitor"
INSTALLED_SCRIPT_PATH="$APP_SUPPORT_DIR/monitor-mac-heat-apps.sh"
RUN_SCRIPT_PATH="$SCRIPT_PATH"
LOG_DIR="${MAC_HEAT_MONITOR_LOG_DIR:-$HOME/Library/Logs/mac-heat-app-monitor}"
SUMMARY_LOG="$LOG_DIR/summary.log"
ERROR_LOG="$LOG_DIR/error.log"
SAMPLES_TSV="$LOG_DIR/samples.tsv"
POWERMETRICS_LOG="$LOG_DIR/powermetrics.log"
LAUNCH_AGENT_LABEL="com.local.mac-heat-app-monitor"
LAUNCH_AGENT_FILE="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"

INTERVAL=30
TOP_N=12
WITH_POWERMETRICS=0

usage() {
  cat <<'USAGE'
Usage:
  ./monitor-mac-heat-apps.sh once [--top N] [--with-powermetrics]
  ./monitor-mac-heat-apps.sh start [--interval SECONDS] [--top N]
  ./monitor-mac-heat-apps.sh stop
  ./monitor-mac-heat-apps.sh status
  ./monitor-mac-heat-apps.sh tail

What it does:
  Samples macOS processes, groups .app helper processes under their parent app
  name, and ranks apps by sustained CPU use. It also records battery and thermal
  pressure hints. This identifies heat suspects; macOS does not expose perfect
  per-app chassis heat attribution.

Logs:
  ~/Library/Logs/mac-heat-app-monitor/summary.log
  ~/Library/Logs/mac-heat-app-monitor/error.log
  ~/Library/Logs/mac-heat-app-monitor/samples.tsv

Notes:
  --with-powermetrics adds raw powermetrics samples only when the current
  process is already running as sudo/root. The LaunchAgent background mode runs
  as your user, so it uses lightweight process sampling by default.
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
      --log-dir)
        [[ $# -ge 2 ]] || { echo "--log-dir requires a value" >&2; exit 2; }
        LOG_DIR="$2"
        SUMMARY_LOG="$LOG_DIR/summary.log"
        ERROR_LOG="$LOG_DIR/error.log"
        SAMPLES_TSV="$LOG_DIR/samples.tsv"
        POWERMETRICS_LOG="$LOG_DIR/powermetrics.log"
        shift 2
        ;;
      --with-powermetrics)
        WITH_POWERMETRICS=1
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
}

read_pid_value() {
  local key="$1"
  [[ -f "$PID_FILE" ]] || return 1
  awk -F= -v key="$key" '
    $1 == key && $2 ~ /^[0-9]+$/ { print $2; found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$PID_FILE"
}

read_file_value() {
  local key="$1"
  [[ -f "$PID_FILE" ]] || return 1
  awk -F= -v key="$key" '
    $1 == key { print substr($0, length(key) + 2); found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$PID_FILE"
}

is_running() {
  local pid="${1:-}"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1
}

write_pid_file() {
  local pid="$1"
  umask 077
  {
    printf 'MONITOR_PID=%s\n' "$pid"
    printf 'LOG_DIR=%s\n' "$LOG_DIR"
    printf 'SUMMARY_LOG=%s\n' "$SUMMARY_LOG"
    printf 'ERROR_LOG=%s\n' "$ERROR_LOG"
    printf 'SAMPLES_TSV=%s\n' "$SAMPLES_TSV"
  } > "$PID_FILE"
}

install_runtime_script() {
  mkdir -p "$APP_SUPPORT_DIR"

  if [[ "$SCRIPT_PATH" != "$INSTALLED_SCRIPT_PATH" ]]; then
    cp "$SCRIPT_PATH" "$INSTALLED_SCRIPT_PATH"
    chmod 755 "$INSTALLED_SCRIPT_PATH"
    xattr -d com.apple.quarantine "$INSTALLED_SCRIPT_PATH" >/dev/null 2>&1 || true
    RUN_SCRIPT_PATH="$INSTALLED_SCRIPT_PATH"
  else
    RUN_SCRIPT_PATH="$SCRIPT_PATH"
  fi
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

write_launch_agent() {
  mkdir -p "$LOG_DIR" "$(dirname "$LAUNCH_AGENT_FILE")"

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
    plist_string "$RUN_SCRIPT_PATH"
    plist_string "run-loop"
    plist_string "--interval"
    plist_string "$INTERVAL"
    plist_string "--top"
    plist_string "$TOP_N"
    plist_string "--log-dir"
    plist_string "$LOG_DIR"
    if [[ "$WITH_POWERMETRICS" -eq 1 ]]; then
      plist_string "--with-powermetrics"
    fi
    cat <<EOF
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$SUMMARY_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$ERROR_LOG")</string>
</dict>
</plist>
EOF
  } > "$LAUNCH_AGENT_FILE"
}

timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

load_snapshot() {
  uptime | sed 's/^[[:space:]]*//'
}

battery_snapshot() {
  pmset -g batt 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/[[:space:]]*$//' || true
}

thermal_snapshot() {
  pmset -g therm 2>/dev/null | tr '\n' ';' | sed 's/;[[:space:]]*/; /g; s/[[:space:]]*$//' || true
}

ensure_sample_header() {
  mkdir -p "$LOG_DIR"
  if [[ ! -f "$SAMPLES_TSV" ]]; then
    printf 'timestamp\tthermal\tbattery\tload\tapp\tcpu_percent\tmemory_mb\tprocess_count\ttop_pid\ttop_command\n' > "$SAMPLES_TSV"
  fi
}

collect_app_rows() {
  ps -Aww -o pid=,ppid=,pcpu=,pmem=,rss=,command= |
    awk -v home="$HOME" '
      function app_name(cmd, first_token, app, n, pieces, base) {
        sub(/^[[:space:]]+/, "", cmd)

        if (match(cmd, /\/[^\/]+\.app\//)) {
          app = substr(cmd, RSTART + 1, RLENGTH - 6)
          return app
        }

        split(cmd, pieces, /[[:space:]]+/)
        first_token = pieces[1]
        n = split(first_token, pieces, "/")
        base = pieces[n]
        if (base == "") {
          base = first_token
        }

        sub(/ Helper$/, "", base)
        sub(/ Helper \([^)]*\)$/, "", base)
        return base
      }

      function safe_command(cmd, value, pieces) {
        sub(/^[[:space:]]+/, "", cmd)

        if (match(cmd, /\/.*\.app(\/|[[:space:]]|$)/)) {
          value = substr(cmd, RSTART, RLENGTH)
          sub(/\/$/, "", value)
          sub(/[[:space:]]+$/, "", value)
        } else {
          split(cmd, pieces, /[[:space:]]+/)
          value = pieces[1]
          if (index(cmd, " ") > 0) {
            value = value " [args redacted]"
          }
        }

        if (home != "" && index(value, home) == 1) {
          value = "~" substr(value, length(home) + 1)
        }
        return value
      }

      {
        pid = $1
        cpu = $3 + 0
        rss_mb = ($5 + 0) / 1024

        cmd = ""
        for (i = 6; i <= NF; i++) {
          cmd = cmd (cmd == "" ? "" : " ") $i
        }
        if (pid == "" || cmd == "") {
          next
        }

        app = app_name(cmd)
        cpu_sum[app] += cpu
        mem_sum[app] += rss_mb
        proc_count[app] += 1

        if (cpu > top_cpu[app]) {
          top_cpu[app] = cpu
          top_pid[app] = pid
          top_cmd[app] = safe_command(cmd)
        }
      }

      END {
        for (app in cpu_sum) {
          printf "%s\t%.1f\t%.0f\t%d\t%s\t%s\n", app, cpu_sum[app], mem_sum[app], proc_count[app], top_pid[app], top_cmd[app]
        }
      }
    ' |
    LC_ALL=C sort -t "$(printf '\t')" -k2,2nr |
    head -n "$TOP_N"
}

append_tsv_rows() {
  local ts="$1"
  local thermal="$2"
  local battery="$3"
  local load="$4"
  local rows="$5"

  ensure_sample_header
  while IFS=$'\t' read -r app cpu mem procs pid cmd; do
    [[ -n "${app:-}" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ts" "$thermal" "$battery" "$load" "$app" "$cpu" "$mem" "$procs" "$pid" "$cmd" >> "$SAMPLES_TSV"
  done <<< "$rows"
}

print_snapshot() {
  local write_tsv="${1:-0}"
  local ts thermal battery load rows rank suspect_app suspect_cpu

  ts="$(timestamp)"
  thermal="$(thermal_snapshot)"
  battery="$(battery_snapshot)"
  load="$(load_snapshot)"
  rows="$(collect_app_rows || true)"

  suspect_app="$(awk -F'\t' 'NR == 1 { print $1 }' <<< "$rows")"
  suspect_cpu="$(awk -F'\t' 'NR == 1 { print $2 }' <<< "$rows")"

  printf '\n[%s]\n' "$ts"
  printf 'Load: %s\n' "$load"
  printf 'Battery: %s\n' "${battery:-unknown}"
  printf 'Thermal: %s\n' "${thermal:-unknown}"
  if [[ -n "${suspect_app:-}" ]]; then
    printf 'Current top heat suspect: %s (%s%% aggregate CPU)\n' "$suspect_app" "$suspect_cpu"
  fi
  printf '\n'
  printf '%-4s %-32s %10s %10s %6s %8s %s\n' "Rank" "App" "CPU%" "Mem MB" "Procs" "Top PID" "Top process"
  printf '%-4s %-32s %10s %10s %6s %8s %s\n' "----" "--------------------------------" "----------" "----------" "------" "--------" "-----------"

  rank=0
  while IFS=$'\t' read -r app cpu mem procs pid cmd; do
    [[ -n "${app:-}" ]] || continue
    rank=$((rank + 1))
    printf '%-4s %-32.32s %10s %10s %6s %8s %s\n' "$rank" "$app" "$cpu" "$mem" "$procs" "$pid" "$cmd"
  done <<< "$rows"

  if [[ "$WITH_POWERMETRICS" -eq 1 ]]; then
    collect_powermetrics_snapshot "$ts"
  fi

  if [[ "$write_tsv" -eq 1 ]]; then
    append_tsv_rows "$ts" "$thermal" "$battery" "$load" "$rows"
  fi
}

collect_powermetrics_snapshot() {
  local ts="$1"

  if ! command -v powermetrics >/dev/null 2>&1; then
    printf '\nPowermetrics: skipped, command not found.\n'
    return
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    printf '\nPowermetrics: skipped, requires sudo/root. Re-run with sudo and --with-powermetrics if you need raw CPU/GPU energy samples.\n'
    return
  fi

  mkdir -p "$LOG_DIR"
  {
    printf '\n[%s]\n' "$ts"
    powermetrics --samplers tasks,thermal,cpu_power,gpu_power --show-process-energy --show-process-gpu -n 1 -i 1000
  } >> "$POWERMETRICS_LOG" 2>&1 || true
  printf '\nPowermetrics: raw sample appended to %s\n' "$POWERMETRICS_LOG"
}

start_monitor() {
  local existing_pid
  local domain

  existing_pid="$(read_pid_value MONITOR_PID || true)"
  if is_running "$existing_pid"; then
    echo "Mac heat app monitor is already running with PID $existing_pid."
    echo "Log: $(read_file_value SUMMARY_LOG || echo "$SUMMARY_LOG")"
    exit 0
  fi

  mkdir -p "$LOG_DIR"
  ensure_sample_header
  install_runtime_script
  write_launch_agent

  domain="$(launch_agent_domain)"
  launchctl bootout "$domain" "$LAUNCH_AGENT_FILE" >/dev/null 2>&1 || true
  launchctl bootstrap "$domain" "$LAUNCH_AGENT_FILE"
  launchctl kickstart -k "$domain/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  sleep 1

  existing_pid="$(read_pid_value MONITOR_PID || true)"
  if is_running "$existing_pid"; then
    echo "Started Mac heat app monitor with PID $existing_pid."
  else
    echo "Requested LaunchAgent start. Check the error log if it does not appear in status shortly."
  fi
  echo "Summary log: $SUMMARY_LOG"
  echo "Error log: $ERROR_LOG"
  echo "Samples TSV: $SAMPLES_TSV"
  echo "LaunchAgent: $LAUNCH_AGENT_FILE"
  echo "Runtime script: $RUN_SCRIPT_PATH"
  echo "Stop it with: $SCRIPT_PATH stop"
}

stop_monitor() {
  local pid
  local domain
  local was_running=0

  pid="$(read_pid_value MONITOR_PID || true)"
  if is_running "$pid"; then
    was_running=1
  fi

  domain="$(launch_agent_domain)"
  launchctl bootout "$domain" "$LAUNCH_AGENT_FILE" >/dev/null 2>&1 || true

  if ! is_running "$pid"; then
    rm -f "$PID_FILE"
    if [[ "$was_running" -eq 1 ]]; then
      echo "Stopped Mac heat app monitor."
    else
      echo "Mac heat app monitor is not running."
    fi
    exit 0
  fi

  echo "Stopping Mac heat app monitor (PID $pid)..."
  kill "$pid" >/dev/null 2>&1 || true

  for _ in 1 2 3 4 5; do
    if ! is_running "$pid"; then
      rm -f "$PID_FILE"
      echo "Stopped."
      exit 0
    fi
    sleep 1
  done

  echo "Process did not stop after 5 seconds; sending SIGKILL."
  kill -9 "$pid" >/dev/null 2>&1 || true
  rm -f "$PID_FILE"
  echo "Stopped."
}

status_monitor() {
  local pid summary error_log samples domain

  pid="$(read_pid_value MONITOR_PID || true)"
  summary="$(read_file_value SUMMARY_LOG || echo "$SUMMARY_LOG")"
  error_log="$(read_file_value ERROR_LOG || echo "$ERROR_LOG")"
  samples="$(read_file_value SAMPLES_TSV || echo "$SAMPLES_TSV")"
  domain="$(launch_agent_domain)"

  if is_running "$pid"; then
    echo "Mac heat app monitor is running with PID $pid."
  else
    echo "Mac heat app monitor is not running."
  fi
  echo "Summary log: $summary"
  echo "Error log: $error_log"
  echo "Samples TSV: $samples"
  echo "LaunchAgent: $LAUNCH_AGENT_FILE"
  if launchctl print "$domain/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1; then
    echo "LaunchAgent state: loaded"
  else
    echo "LaunchAgent state: not loaded"
  fi

  if [[ -f "$summary" ]]; then
    echo
    echo "Last summary lines:"
    tail -n 30 "$summary"
  fi
}

tail_monitor() {
  local summary
  summary="$(read_file_value SUMMARY_LOG || echo "$SUMMARY_LOG")"
  mkdir -p "$(dirname "$summary")"
  touch "$summary"
  tail -n 80 -f "$summary"
}

run_loop() {
  mkdir -p "$LOG_DIR"
  ensure_sample_header
  write_pid_file "$$"

  cleanup() {
    if [[ "$(read_pid_value MONITOR_PID || true)" == "$$" ]]; then
      rm -f "$PID_FILE"
    fi
    printf '\n[%s] Monitor stopped.\n' "$(timestamp)"
  }

  trap 'cleanup; exit 0' INT TERM

  printf '\n[%s] Monitor started. Interval=%ss Top=%s LogDir=%s\n' "$(timestamp)" "$INTERVAL" "$TOP_N" "$LOG_DIR"
  while true; do
    print_snapshot 1
    sleep "$INTERVAL" &
    wait "$!" || true
  done
}

COMMAND="${1:-once}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$COMMAND" in
  once)
    parse_options "$@"
    print_snapshot 0
    ;;
  start)
    parse_options "$@"
    start_monitor
    ;;
  stop)
    parse_options "$@"
    stop_monitor
    ;;
  status)
    parse_options "$@"
    status_monitor
    ;;
  tail)
    parse_options "$@"
    tail_monitor
    ;;
  run-loop)
    parse_options "$@"
    run_loop
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
