#!/usr/bin/env python3
import argparse
import csv
import json
import os
import re
import signal
import subprocess
import threading
import time
from collections import defaultdict, deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


HTML = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Mac Heat Monitor</title>
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <style>
    :root {
      color-scheme: light;
      --bg: #f6f7f9;
      --panel: #ffffff;
      --surface: #ffffff;
      --text: #111827;
      --muted: #6b7280;
      --line: #d8dde5;
      --soft-line: #edf0f4;
      --table-head: #fbfcfd;
      --hover-line: #aab4c2;
      --blue: #2563eb;
      --red: #dc2626;
      --green: #059669;
      --amber: #d97706;
      --violet: #7c3aed;
      --cyan: #0891b2;
      --shadow: 0 1px 2px rgba(15, 23, 42, 0.06);
      --popover-shadow: 0 14px 34px rgba(15, 23, 42, 0.16);
    }

    @media (prefers-color-scheme: dark) {
      :root {
        color-scheme: dark;
        --bg: #0f1115;
        --panel: #171a21;
        --surface: #1d212a;
        --text: #f2f5f8;
        --muted: #a2abba;
        --line: #303642;
        --soft-line: #252b35;
        --table-head: #1b2028;
        --hover-line: #4a5568;
        --blue: #60a5fa;
        --red: #f87171;
        --green: #34d399;
        --amber: #fbbf24;
        --violet: #a78bfa;
        --cyan: #22d3ee;
        --shadow: 0 1px 2px rgba(0, 0, 0, 0.28);
        --popover-shadow: 0 16px 38px rgba(0, 0, 0, 0.42);
      }
    }

    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      padding: 18px 24px;
      border-bottom: 1px solid var(--line);
      background: var(--panel);
      position: sticky;
      top: 0;
      z-index: 5;
    }

    h1 {
      margin: 0;
      font-size: 20px;
      font-weight: 680;
      letter-spacing: 0;
    }

    .toolbar {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      justify-content: flex-end;
    }

    select, button {
      height: 34px;
      border-radius: 7px;
      border: 1px solid var(--line);
      background: var(--surface);
      color: var(--text);
      padding: 0 10px;
      font: inherit;
    }

    button {
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }

    button:hover, select:hover { border-color: var(--hover-line); }

    main {
      width: min(1420px, 100%);
      margin: 0 auto;
      padding: 18px 24px 28px;
    }

    .status-line {
      display: flex;
      align-items: center;
      gap: 8px;
      color: var(--muted);
      min-width: 0;
      white-space: nowrap;
    }

    .dot {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      background: var(--green);
      box-shadow: 0 0 0 3px rgba(5, 150, 105, 0.14);
      flex: 0 0 auto;
    }

    .dot.warn {
      background: var(--amber);
      box-shadow: 0 0 0 3px rgba(217, 119, 6, 0.14);
    }

    .dot.down {
      background: var(--red);
      box-shadow: 0 0 0 3px rgba(220, 38, 38, 0.14);
    }

    .metrics {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 12px;
      margin-bottom: 14px;
    }

    .metric, .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: var(--shadow);
    }

    .metric {
      padding: 16px 14px;
      min-height: 96px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      gap: 8px;
      position: relative;
      outline: none;
    }

    .label {
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      font-weight: 650;
    }

    .metric-popover {
      position: absolute;
      top: calc(100% + 6px);
      left: 0;
      z-index: 10;
      min-width: min(360px, calc(100vw - 48px));
      max-width: 440px;
      padding: 14px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--surface);
      box-shadow: var(--popover-shadow);
      opacity: 0;
      pointer-events: none;
      transform: translateY(-4px);
      transition: opacity 120ms ease, transform 120ms ease;
    }

    .metric-popover::before {
      content: "";
      position: absolute;
      left: 0;
      right: 0;
      top: -8px;
      height: 8px;
    }

    .metric:hover,
    .metric:focus,
    .metric:focus-within {
      border-color: var(--hover-line);
    }

    .metric:hover .metric-popover,
    .metric:focus .metric-popover,
    .metric:focus-within .metric-popover {
      opacity: 1;
      pointer-events: auto;
      transform: translateY(0);
    }

    .metric:nth-child(4n) .metric-popover {
      left: auto;
      right: 0;
    }

    .value {
      font-size: 24px;
      font-weight: 720;
      letter-spacing: 0;
      min-width: 0;
      overflow-wrap: anywhere;
    }

    .subvalue {
      color: var(--muted);
      min-width: 0;
      overflow-wrap: anywhere;
    }

    .grid {
      display: grid;
      grid-template-columns: minmax(0, 1.35fr) minmax(380px, 0.65fr);
      gap: 14px;
      align-items: start;
    }

    .panel {
      min-width: 0;
      overflow: hidden;
    }

    .panel-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      padding: 13px 14px;
      border-bottom: 1px solid var(--line);
    }

    h2 {
      margin: 0;
      font-size: 15px;
      font-weight: 690;
      letter-spacing: 0;
    }

    .chart-wrap {
      height: 380px;
      padding: 10px 12px 12px;
    }

    canvas {
      width: 100%;
      height: 100%;
      display: block;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
    }

    th, td {
      padding: 10px 12px;
      border-bottom: 1px solid var(--soft-line);
      text-align: left;
      vertical-align: top;
    }

    th {
      color: var(--muted);
      font-size: 12px;
      font-weight: 680;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      background: var(--table-head);
    }

    td.num, th.num { text-align: right; }

    .app-name {
      font-weight: 660;
      overflow-wrap: anywhere;
    }

    .command {
      color: var(--muted);
      font-size: 12px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      margin-top: 2px;
    }

    .legend {
      display: flex;
      gap: 10px;
      align-items: center;
      flex-wrap: wrap;
      color: var(--muted);
      font-size: 12px;
    }

    .legend-item {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      min-width: 0;
    }

    .swatch {
      width: 10px;
      height: 10px;
      border-radius: 2px;
      flex: 0 0 auto;
    }

    .empty {
      padding: 34px 16px;
      color: var(--muted);
      text-align: center;
    }

    @media (max-width: 980px) {
      header { align-items: flex-start; flex-direction: column; }
      .toolbar { justify-content: flex-start; }
      .metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .grid { grid-template-columns: minmax(0, 1fr); }
      .metric:nth-child(n + 3) .metric-popover {
        top: auto;
        bottom: calc(100% + 6px);
      }
      .metric:nth-child(n + 3) .metric-popover::before {
        top: auto;
        bottom: -8px;
      }
    }

    @media (max-width: 620px) {
      main, header { padding-left: 14px; padding-right: 14px; }
      .metrics { grid-template-columns: minmax(0, 1fr); }
      .metric-popover {
        left: 0;
        right: auto;
        min-width: min(360px, calc(100vw - 28px));
      }
      .metric:nth-child(n + 3) .metric-popover {
        top: calc(100% + 6px);
        bottom: auto;
      }
      .metric:nth-child(n + 3) .metric-popover::before {
        top: -8px;
        bottom: auto;
      }
      th, td { padding: 9px 8px; }
      .hide-sm { display: none; }
      .chart-wrap { height: 310px; }
    }
  </style>
</head>
<body>
  <header>
    <div>
      <h1>Mac Heat Monitor</h1>
      <div class="status-line"><span id="stateDot" class="dot warn"></span><span id="stateText">Loading</span></div>
    </div>
    <div class="toolbar">
      <select id="windowSelect" aria-label="Time window">
        <option value="30">30 min</option>
        <option value="120" selected>2 hours</option>
        <option value="360">6 hours</option>
        <option value="1440">24 hours</option>
      </select>
      <button id="refreshButton" type="button" title="Refresh now">Refresh</button>
    </div>
  </header>

  <main>
    <section class="metrics">
      <div class="metric" tabindex="0">
        <div class="label">Top Suspect</div>
        <div id="topApp" class="value">-</div>
        <div class="metric-popover" role="tooltip">
          <div id="topCpu" class="subvalue">No sample yet</div>
        </div>
      </div>
      <div class="metric" tabindex="0">
        <div class="label">Last Sample</div>
        <div id="lastSample" class="value">-</div>
        <div class="metric-popover" role="tooltip">
          <div id="sampleAge" class="subvalue">Waiting for data</div>
        </div>
      </div>
      <div class="metric" tabindex="0">
        <div class="label">Battery</div>
        <div id="batteryShort" class="value">-</div>
        <div class="metric-popover" role="tooltip">
          <div id="batteryLong" class="subvalue">-</div>
        </div>
      </div>
      <div class="metric" tabindex="0">
        <div class="label">Thermal</div>
        <div id="thermalShort" class="value">-</div>
        <div class="metric-popover" role="tooltip">
          <div id="thermalLong" class="subvalue">-</div>
        </div>
      </div>
    </section>

    <section class="grid">
      <div class="panel">
        <div class="panel-head">
          <h2>CPU Trend</h2>
          <div id="legend" class="legend"></div>
        </div>
        <div class="chart-wrap">
          <canvas id="chart"></canvas>
        </div>
      </div>
      <div class="panel">
        <div class="panel-head">
          <h2>Sustained Load</h2>
          <div id="rowCount" class="subvalue"></div>
        </div>
        <table>
          <thead>
            <tr>
              <th>App</th>
              <th class="num">Avg</th>
              <th class="num">Max</th>
              <th class="num hide-sm">Mem</th>
            </tr>
          </thead>
          <tbody id="leaderboard"></tbody>
        </table>
      </div>
    </section>
  </main>

  <script>
    const colors = ["#2563eb", "#dc2626", "#059669", "#7c3aed", "#d97706", "#0891b2", "#be123c", "#4b5563"];
    const chart = document.getElementById("chart");
    const ctx = chart.getContext("2d");
    let latestData = null;

    function setText(id, value) {
      document.getElementById(id).textContent = value || "-";
    }

    function formatTime(ms) {
      if (!ms) return "-";
      return new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
    }

    function formatAge(seconds) {
      if (seconds == null) return "Waiting for data";
      if (seconds < 60) return `${Math.max(0, Math.round(seconds))}s ago`;
      if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`;
      return `${Math.round(seconds / 3600)}h ago`;
    }

    function shortBattery(text) {
      const match = (text || "").match(/(\d+%)/);
      return match ? match[1] : "-";
    }

    function shortThermal(text) {
      if (!text) return "-";
      if (/No thermal warning/i.test(text)) return "Normal";
      if (/thermal/i.test(text)) return "Warning";
      return "Unknown";
    }

    function statusLabel(monitor, stale) {
      if (!monitor || !monitor.running) return ["down", "Monitor stopped"];
      if (stale) return ["warn", "Monitor running, data stale"];
      return ["", "Monitor running"];
    }

    function fitCanvas() {
      const rect = chart.getBoundingClientRect();
      const dpr = window.devicePixelRatio || 1;
      const width = Math.max(1, Math.round(rect.width * dpr));
      const height = Math.max(1, Math.round(rect.height * dpr));
      if (chart.width !== width || chart.height !== height) {
        chart.width = width;
        chart.height = height;
      }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      return { width: rect.width, height: rect.height };
    }

    function cssVar(name) {
      return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    }

    function drawChart(data) {
      const { width, height } = fitCanvas();
      ctx.clearRect(0, 0, width, height);

      const series = data.series || [];
      const apps = data.top_apps || [];
      const pad = { left: 42, right: 12, top: 12, bottom: 30 };
      const plotW = Math.max(10, width - pad.left - pad.right);
      const plotH = Math.max(10, height - pad.top - pad.bottom);
      const gridColor = cssVar("--line") || "#d8dde5";
      const mutedColor = cssVar("--muted") || "#6b7280";

      ctx.font = "12px -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif";
      ctx.strokeStyle = gridColor;
      ctx.lineWidth = 1;
      ctx.fillStyle = mutedColor;

      if (!series.length || !apps.length) {
        ctx.fillText("No samples yet", pad.left, pad.top + 24);
        return;
      }

      const maxY = Math.max(10, Math.ceil((data.max_cpu || 10) / 25) * 25);
      for (let i = 0; i <= 4; i++) {
        const y = pad.top + plotH - (plotH * i / 4);
        const value = Math.round(maxY * i / 4);
        ctx.beginPath();
        ctx.moveTo(pad.left, y);
        ctx.lineTo(pad.left + plotW, y);
        ctx.stroke();
        ctx.fillText(`${value}%`, 4, y + 4);
      }

      const first = series[0].epoch_ms;
      const last = series[series.length - 1].epoch_ms;
      const span = Math.max(1, last - first);

      apps.forEach((app, index) => {
        ctx.strokeStyle = colors[index % colors.length];
        ctx.lineWidth = 2;
        ctx.beginPath();
        let moved = false;
        series.forEach(point => {
          const x = pad.left + ((point.epoch_ms - first) / span) * plotW;
          const y = pad.top + plotH - ((point.apps[app] || 0) / maxY) * plotH;
          if (!moved) {
            ctx.moveTo(x, y);
            moved = true;
          } else {
            ctx.lineTo(x, y);
          }
        });
        ctx.stroke();
      });

      ctx.fillStyle = mutedColor;
      ctx.fillText(formatTime(first), pad.left, height - 8);
      const endLabel = formatTime(last);
      const endWidth = ctx.measureText(endLabel).width;
      ctx.fillText(endLabel, pad.left + plotW - endWidth, height - 8);
    }

    function render(data) {
      latestData = data;
      const latest = data.latest || {};
      const leader = data.leaderboard || [];
      const top = leader[0];
      const stale = !!data.stale;
      const [dotClass, stateText] = statusLabel(data.monitor, stale);
      const dot = document.getElementById("stateDot");
      dot.className = `dot ${dotClass}`;
      setText("stateText", stateText);

      setText("topApp", top ? top.app : "-");
      setText("topCpu", top ? `${top.avg_cpu.toFixed(1)}% avg · ${top.max_cpu.toFixed(1)}% max` : "No sample yet");
      setText("lastSample", formatTime(latest.epoch_ms));
      setText("sampleAge", formatAge(data.latest_age_seconds));
      setText("batteryShort", shortBattery(latest.battery));
      setText("batteryLong", latest.battery || "-");
      setText("thermalShort", shortThermal(latest.thermal));
      setText("thermalLong", latest.thermal || "-");
      setText("rowCount", `${data.sample_count || 0} rows`);

      const tbody = document.getElementById("leaderboard");
      tbody.innerHTML = "";
      if (!leader.length) {
        tbody.innerHTML = `<tr><td colspan="4"><div class="empty">No samples yet</div></td></tr>`;
      } else {
        leader.forEach(row => {
          const tr = document.createElement("tr");
          tr.innerHTML = `
            <td><div class="app-name"></div><div class="command"></div></td>
            <td class="num">${row.avg_cpu.toFixed(1)}%</td>
            <td class="num">${row.max_cpu.toFixed(1)}%</td>
            <td class="num hide-sm">${Math.round(row.memory_mb || 0)}</td>
          `;
          tr.querySelector(".app-name").textContent = row.app;
          tr.querySelector(".command").textContent = row.top_command || "";
          tbody.appendChild(tr);
        });
      }

      const legend = document.getElementById("legend");
      legend.innerHTML = "";
      (data.top_apps || []).forEach((app, index) => {
        const item = document.createElement("span");
        item.className = "legend-item";
        item.innerHTML = `<span class="swatch" style="background:${colors[index % colors.length]}"></span><span></span>`;
        item.querySelector("span:last-child").textContent = app;
        legend.appendChild(item);
      });

      drawChart(data);
    }

    async function load() {
      const minutes = document.getElementById("windowSelect").value;
      const response = await fetch(`/api/overview?minutes=${encodeURIComponent(minutes)}&limit=8`, { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      render(await response.json());
    }

    document.getElementById("refreshButton").addEventListener("click", () => load().catch(console.error));
    document.getElementById("windowSelect").addEventListener("change", () => load().catch(console.error));
    window.addEventListener("resize", () => latestData && drawChart(latestData));
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => latestData && drawChart(latestData));
    load().catch(console.error);
    setInterval(() => load().catch(console.error), 5000);
  </script>
</body>
</html>
"""


FAVICON_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <linearGradient id="heat" x1="16" y1="6" x2="50" y2="58" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#f97316"/>
      <stop offset="0.55" stop-color="#dc2626"/>
      <stop offset="1" stop-color="#7c3aed"/>
    </linearGradient>
  </defs>
  <rect width="64" height="64" rx="14" fill="#111827"/>
  <path fill="url(#heat)" d="M32 8c10 10 17 18 17 30 0 10-8 18-17 18s-17-8-17-18c0-7 3-13 8-18-1 7 2 11 6 13 1-9 3-17 3-25z"/>
  <path fill="#fff" d="M32 50c6 0 11-5 11-11 0-5-3-9-7-14 0 6-2 12-4 16-3-2-4-5-4-9-4 4-7 7-7 12 0 4 5 6 11 6z" opacity=".88"/>
  <path fill="#111827" d="M28 24h3v-4h3v4h3v3h-3v4h-3v-4h-3v-3z" opacity=".86"/>
</svg>
"""


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return None


def sanitize_command(command):
    command = (command or "").strip()
    if not command:
        return ""

    home = str(Path.home())
    app_match = re.search(r"(/.*?\.app)(?:/|\s|$)", command)
    if app_match:
        value = app_match.group(1)
    else:
        value = command.split()[0]
        if len(command.split()) > 1:
            value = f"{value} [args redacted]"

    if home and value.startswith(home):
        value = "~" + value[len(home) :]
    return value


def read_tail_lines(path, max_lines=25000):
    sample_path = Path(path).expanduser()
    if not sample_path.exists():
        return []
    with sample_path.open("r", encoding="utf-8", errors="replace", newline="") as handle:
        return list(deque(handle, maxlen=max_lines))


def read_samples(path, minutes):
    lines = read_tail_lines(path)
    if not lines:
        return []

    cutoff = None
    if minutes > 0:
        cutoff = time.time() - (minutes * 60)

    rows = []
    for row in csv.reader(lines, delimiter="\t"):
        if not row or row[0] == "timestamp" or len(row) < 9:
            continue
        if len(row) < 10:
            row.append("")
        elif len(row) > 10:
            row = row[:9] + ["\t".join(row[9:])]

        ts = parse_ts(row[0])
        epoch = ts.timestamp() if ts else None
        if cutoff and epoch and epoch < cutoff:
            continue

        try:
            cpu = float(row[5])
        except ValueError:
            cpu = 0.0
        try:
            memory = float(row[6])
        except ValueError:
            memory = 0.0
        try:
            process_count = int(float(row[7]))
        except ValueError:
            process_count = 0

        rows.append(
            {
                "timestamp": row[0],
                "epoch_ms": int(epoch * 1000) if epoch else None,
                "thermal": row[1],
                "battery": row[2],
                "load": row[3],
                "app": row[4],
                "cpu_percent": cpu,
                "memory_mb": memory,
                "process_count": process_count,
                "top_pid": row[8],
                "top_command": sanitize_command(row[9]),
            }
        )
    return rows


def read_key_file(path):
    values = {}
    if not path:
        return values
    key_path = Path(path).expanduser()
    if not key_path.exists():
        return values
    for line in key_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def pid_running(pid):
    try:
        pid_int = int(pid)
    except (TypeError, ValueError):
        return False
    try:
        os.kill(pid_int, 0)
        return True
    except OSError:
        return False


def launch_agent_loaded(label):
    if not label:
        return False
    domain = f"gui/{os.getuid()}/{label}"
    try:
        result = subprocess.run(
            ["launchctl", "print", domain],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        return False
    return result.returncode == 0


def monitor_state(pid_file, label):
    values = read_key_file(pid_file)
    pid = values.get("MONITOR_PID")
    running = pid_running(pid)
    loaded = launch_agent_loaded(label)
    return {
        "running": bool(running or loaded),
        "pid": int(pid) if pid and pid.isdigit() else None,
        "launch_agent_loaded": loaded,
    }


def build_overview(config, minutes, limit):
    samples = read_samples(config.samples, minutes)
    latest_ts = None
    latest_rows = []
    if samples:
        latest_ts = max((row["timestamp"] for row in samples if row["timestamp"]), default=None)
        latest_rows = [row for row in samples if row["timestamp"] == latest_ts]

    stats = defaultdict(
        lambda: {
            "total_cpu": 0.0,
            "max_cpu": 0.0,
            "samples": 0,
            "latest_cpu": 0.0,
            "memory_mb": 0.0,
            "process_count": 0,
            "top_pid": "",
            "top_command": "",
            "last_epoch_ms": 0,
        }
    )

    for row in samples:
        app_stats = stats[row["app"]]
        app_stats["total_cpu"] += row["cpu_percent"]
        app_stats["max_cpu"] = max(app_stats["max_cpu"], row["cpu_percent"])
        app_stats["samples"] += 1
        if row["epoch_ms"] and row["epoch_ms"] >= app_stats["last_epoch_ms"]:
            app_stats["latest_cpu"] = row["cpu_percent"]
            app_stats["memory_mb"] = row["memory_mb"]
            app_stats["process_count"] = row["process_count"]
            app_stats["top_pid"] = row["top_pid"]
            app_stats["top_command"] = row["top_command"]
            app_stats["last_epoch_ms"] = row["epoch_ms"]

    leaderboard = []
    for app, app_stats in stats.items():
        sample_count = max(1, app_stats["samples"])
        avg_cpu = app_stats["total_cpu"] / sample_count
        leaderboard.append(
            {
                "app": app,
                "avg_cpu": round(avg_cpu, 2),
                "max_cpu": round(app_stats["max_cpu"], 2),
                "latest_cpu": round(app_stats["latest_cpu"], 2),
                "memory_mb": round(app_stats["memory_mb"], 1),
                "process_count": app_stats["process_count"],
                "samples": app_stats["samples"],
                "top_pid": app_stats["top_pid"],
                "top_command": app_stats["top_command"],
            }
        )

    leaderboard.sort(key=lambda row: (row["avg_cpu"], row["max_cpu"]), reverse=True)
    leaderboard = leaderboard[:limit]
    top_apps = [row["app"] for row in leaderboard[: min(limit, 8)]]

    by_timestamp = defaultdict(dict)
    epoch_by_timestamp = {}
    max_cpu = 0.0
    for row in samples:
        if row["app"] not in top_apps:
            continue
        by_timestamp[row["timestamp"]][row["app"]] = row["cpu_percent"]
        if row["epoch_ms"]:
            epoch_by_timestamp[row["timestamp"]] = row["epoch_ms"]
        max_cpu = max(max_cpu, row["cpu_percent"])

    series = [
        {"timestamp": ts, "epoch_ms": epoch_by_timestamp.get(ts), "apps": apps}
        for ts, apps in sorted(by_timestamp.items(), key=lambda item: epoch_by_timestamp.get(item[0], 0))
    ][-360:]

    latest = latest_rows[0] if latest_rows else {}
    if latest_rows:
        latest = max(latest_rows, key=lambda row: row["cpu_percent"])

    now_ms = int(time.time() * 1000)
    latest_epoch = latest.get("epoch_ms") if latest else None
    age_seconds = (now_ms - latest_epoch) / 1000 if latest_epoch else None

    return {
        "monitor": monitor_state(config.monitor_pid_file, config.monitor_label),
        "latest": latest,
        "latest_age_seconds": age_seconds,
        "stale": bool(age_seconds is not None and age_seconds > 120),
        "sample_count": len(samples),
        "leaderboard": leaderboard,
        "top_apps": top_apps,
        "series": series,
        "max_cpu": round(max_cpu, 2),
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }


def tail_text(path, lines=120):
    target = Path(path).expanduser()
    if not target.exists():
        return ""
    with target.open("r", encoding="utf-8", errors="replace") as handle:
        return "".join(deque(handle, maxlen=lines))


class Handler(BaseHTTPRequestHandler):
    server_version = "MacHeatDashboard/1.0"

    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        if parsed.path == "/":
            self.write_bytes(HTML.encode("utf-8"), "text/html; charset=utf-8")
            return
        if parsed.path == "/favicon.svg":
            self.write_bytes(FAVICON_SVG.encode("utf-8"), "image/svg+xml")
            return
        if parsed.path == "/health":
            self.write_json({"ok": True})
            return
        if parsed.path == "/api/overview":
            minutes = self.int_param(params, "minutes", 120, 1, 10080)
            limit = self.int_param(params, "limit", 8, 1, 24)
            self.write_json(build_overview(self.server.config, minutes, limit))
            return
        if parsed.path == "/api/logs":
            log_type = params.get("type", ["summary"])[0]
            path = self.server.config.error_log if log_type == "error" else self.server.config.summary_log
            lines = self.int_param(params, "lines", 120, 1, 1000)
            self.write_bytes(tail_text(path, lines).encode("utf-8"), "text/plain; charset=utf-8")
            return
        self.send_error(404)

    def log_message(self, fmt, *args):
        print(f"{self.log_date_time_string()} {self.address_string()} {fmt % args}")

    def int_param(self, params, key, default, min_value, max_value):
        try:
            value = int(params.get(key, [default])[0])
        except (TypeError, ValueError):
            value = default
        return max(min_value, min(max_value, value))

    def write_json(self, payload):
        self.write_bytes(json.dumps(payload, separators=(",", ":")).encode("utf-8"), "application/json")

    def write_bytes(self, payload, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def write_pid(path):
    if not path:
        return
    pid_path = Path(path).expanduser()
    pid_path.parent.mkdir(parents=True, exist_ok=True)
    pid_path.write_text(str(os.getpid()), encoding="utf-8")


def remove_pid(path):
    if path:
        try:
            Path(path).expanduser().unlink()
        except FileNotFoundError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--samples", default=os.path.expanduser("~/Library/Logs/mac-heat-app-monitor/samples.tsv"))
    parser.add_argument("--summary-log", default=os.path.expanduser("~/Library/Logs/mac-heat-app-monitor/summary.log"))
    parser.add_argument("--error-log", default=os.path.expanduser("~/Library/Logs/mac-heat-app-monitor/error.log"))
    parser.add_argument("--monitor-pid-file", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "mac-heat-app-monitor.pid"))
    parser.add_argument("--dashboard-pid-file", default=os.path.expanduser("~/Library/Application Support/mac-heat-app-monitor/dashboard.pid"))
    parser.add_argument("--monitor-label", default="com.local.mac-heat-app-monitor")
    args = parser.parse_args()

    write_pid(args.dashboard_pid_file)

    class ConfiguredServer(ThreadingHTTPServer):
        daemon_threads = True

    server = ConfiguredServer((args.host, args.port), Handler)
    server.config = args

    def stop(_signum, _frame):
        remove_pid(args.dashboard_pid_file)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    print(f"Mac heat dashboard listening on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    finally:
        remove_pid(args.dashboard_pid_file)
        server.server_close()


if __name__ == "__main__":
    main()
