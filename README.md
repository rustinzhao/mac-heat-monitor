# Mac Heat Monitor

Mac Heat Monitor 是一组 macOS 本地脚本，用来定位“哪个 App 正在让 Mac 持续发热”。它会按时间间隔采样进程 CPU、内存、电池、系统负载和 thermal pressure 信息，把数据写入 TSV，并提供一个只监听本机地址的网页 dashboard。

## 适合什么场景

- Mac 风扇转得很快，或者机身发烫，但 Activity Monitor 里瞬间数据不够好判断。
- 想长时间观察某个 App 是否持续占用 CPU。
- 想记录一段时间内的 CPU 趋势、电池状态和 thermal pressure。
- 想让 Mac 在观察期间尽量不要 idle sleep，然后再恢复默认睡眠行为。

## 功能

- 按 App 聚合 `.app` helper 进程，而不是只看单个 PID。
- 记录当前 top heat suspect、CPU、内存、进程数和已脱敏的 top process 标签。
- 写入 `samples.tsv`，方便导入 Numbers、Excel、Google Sheets 或后续脚本分析。
- 用 LaunchAgent 在当前用户登录后后台运行 monitor 和 dashboard。
- 本地网页 dashboard 支持 CPU 趋势、Top Suspect、Last Sample、Battery、Thermal 和 Sustained Load。
- 附带 keep-awake helper，可在监控期间阻止 macOS idle sleep。
- 不需要第三方 Python 包。

## 文件

```text
.
├── mac-heat-dashboard.sh                  # dashboard 管理脚本
├── mac-heat-dashboard-server.py           # Python 本地网页服务
├── monitor-mac-heat-apps.sh               # 后台采样器
├── keep-mac-awake-until-battery-empty.sh  # 可选：监控期间保持唤醒
└── restore-mac-sleep-normal.sh            # 可选：恢复默认睡眠行为
```

## 系统要求

- macOS。
- Bash，macOS 自带即可。
- Python 3，用于本地 dashboard 服务。
- macOS 常见命令：`launchctl`、`pmset`、`ps`、`awk`、`sed`、`curl`。
- 可选：`powermetrics`，需要 sudo/root，只用于额外采集底层电源和 thermal 原始数据。

检查 Python：

```bash
python3 --version
```

如果 `python3` 不在默认路径，可以用 `PYTHON_BIN` 指定：

```bash
PYTHON_BIN=/opt/homebrew/bin/python3 ./mac-heat-dashboard.sh start --open
```

## 安装

```bash
git clone https://github.com/<your-github-user>/mac-heat-monitor.git
cd mac-heat-monitor
chmod +x *.sh
```

如果 macOS 给下载的脚本加了 quarantine 标记，可以移除：

```bash
xattr -dr com.apple.quarantine .
```

## 快速开始

启动后台 monitor 和 dashboard：

```bash
./mac-heat-dashboard.sh start --open
```

默认 dashboard 地址：

```text
http://127.0.0.1:8765
```

默认配置：

- 每 30 秒采样一次。
- 每次采样记录 Top 12 个高 CPU App。
- dashboard 只绑定 `127.0.0.1`，默认只允许本机访问。
- monitor 和 dashboard 都通过当前用户的 LaunchAgent 后台运行。

自定义采样间隔、Top 数量和端口：

```bash
./mac-heat-dashboard.sh start --interval 15 --top 20 --port 8765 --open
```

## 长时间监控时保持 Mac 唤醒

如果你要放着 Mac 观察半小时到几个小时，建议先启动 keep-awake helper，避免 idle sleep 影响采样。

在一个终端里运行：

```bash
./keep-mac-awake-until-battery-empty.sh
```

它会保持运行。再开另一个终端启动 dashboard：

```bash
./mac-heat-dashboard.sh start --open
```

如果你希望 keep-awake 在后台运行：

```bash
./keep-mac-awake-until-battery-empty.sh >/tmp/mac-heat-keep-awake.log 2>&1 &
```

恢复默认 idle sleep 行为：

```bash
./restore-mac-sleep-normal.sh
```

如果你怀疑有遗留的 `caffeinate -dims` 进程：

```bash
./restore-mac-sleep-normal.sh --include-orphan-caffeinate
```

注意：macOS 仍可能因为合盖、极低电量、thermal 保护、硬件保护或系统策略进入睡眠或关机。

## Dashboard 命令

```bash
./mac-heat-dashboard.sh start
./mac-heat-dashboard.sh start --interval 30 --top 12 --port 8765 --open
./mac-heat-dashboard.sh status
./mac-heat-dashboard.sh open
./mac-heat-dashboard.sh tail
./mac-heat-dashboard.sh stop
./mac-heat-dashboard.sh stop-all
```

命令说明：

- `start`：安装运行副本，写入 LaunchAgent，启动 monitor 和 dashboard。
- `status`：检查 dashboard PID、LaunchAgent 状态和 HTTP health。
- `open`：用默认浏览器打开 dashboard。
- `tail`：持续查看 dashboard stdout/stderr 日志。
- `stop`：停止 dashboard。
- `stop-all`：停止 dashboard，并停止后台 monitor。

## 只运行命令行 Monitor

采样一次：

```bash
./monitor-mac-heat-apps.sh once
```

采样一次并显示 Top 20：

```bash
./monitor-mac-heat-apps.sh once --top 20
```

后台启动 monitor：

```bash
./monitor-mac-heat-apps.sh start --interval 30 --top 12
```

查看状态：

```bash
./monitor-mac-heat-apps.sh status
```

查看实时日志：

```bash
./monitor-mac-heat-apps.sh tail
```

停止 monitor：

```bash
./monitor-mac-heat-apps.sh stop
```

## 配置

Dashboard 支持：

```bash
./mac-heat-dashboard.sh start \
  --interval 30 \
  --top 12 \
  --host 127.0.0.1 \
  --port 8765 \
  --open
```

Monitor 支持：

```bash
./monitor-mac-heat-apps.sh start \
  --interval 30 \
  --top 12 \
  --log-dir "$HOME/Library/Logs/mac-heat-app-monitor"
```

环境变量：

- `MAC_HEAT_MONITOR_LOG_DIR`：修改 monitor 和 dashboard 的默认日志目录。
- `PYTHON_BIN`：指定 dashboard 使用的 Python 3。

示例：

```bash
MAC_HEAT_MONITOR_LOG_DIR="$HOME/mac-heat-logs" \
  ./mac-heat-dashboard.sh start --interval 10 --top 15 --open
```

## 运行时文件

启动后，脚本会把后台运行需要的文件复制到当前用户目录。这样即使你之后移动 clone 目录，LaunchAgent 也能继续找到运行脚本。

```text
~/Library/Application Support/mac-heat-app-monitor/
├── monitor-mac-heat-apps.sh
├── mac-heat-dashboard-server.py
└── dashboard.pid
```

LaunchAgent：

```text
~/Library/LaunchAgents/com.local.mac-heat-app-monitor.plist
~/Library/LaunchAgents/com.local.mac-heat-dashboard.plist
```

日志：

```text
~/Library/Logs/mac-heat-app-monitor/summary.log
~/Library/Logs/mac-heat-app-monitor/error.log
~/Library/Logs/mac-heat-app-monitor/samples.tsv
~/Library/Logs/mac-heat-app-monitor/dashboard.log
~/Library/Logs/mac-heat-app-monitor/dashboard-error.log
```

## 怎么看 Dashboard

- `Top Suspect`：当前时间窗口里平均 CPU 最高的 App。它更适合判断持续发热来源，而不是瞬间峰值。
- `Last Sample`：最近一次采样时间。超过约 120 秒会显示 stale，通常说明 monitor 没在持续写入数据。
- `Battery`：来自 `pmset -g batt` 的电池状态摘要。
- `Thermal`：来自 `pmset -g therm` 的 thermal pressure 摘要。
- `CPU Trend`：展示高 CPU App 在选定时间窗口中的趋势。
- `Sustained Load`：按平均 CPU 和最大 CPU 排名的 App 列表。

重要限制：macOS 不提供完美的“每个 App 对机身温度贡献值”。这个工具使用持续 CPU、进程聚合、系统 thermal 和电池状态来推断发热嫌疑对象。

## 原始数据

`samples.tsv` 字段：

```text
timestamp
thermal
battery
load
app
cpu_percent
memory_mb
process_count
top_pid
top_command
```

查看 TSV：

```bash
column -t -s $'\t' ~/Library/Logs/mac-heat-app-monitor/samples.tsv | less -S
```

导出最近数据：

```bash
tail -n 200 ~/Library/Logs/mac-heat-app-monitor/samples.tsv > /tmp/mac-heat-recent.tsv
```

## 使用 powermetrics

`powermetrics` 可以给一次性采样增加更底层的 CPU/GPU/thermal 原始输出，但它需要 root 权限。

```bash
sudo ./monitor-mac-heat-apps.sh once --with-powermetrics
```

输出会追加到：

```text
~/Library/Logs/mac-heat-app-monitor/powermetrics.log
```

后台 LaunchAgent 默认以当前用户运行，不会自动拥有 sudo 权限，所以长期后台监控默认使用轻量 process sampling。

## 停止和卸载

停止 dashboard 和 monitor：

```bash
./mac-heat-dashboard.sh stop-all
```

恢复默认睡眠行为：

```bash
./restore-mac-sleep-normal.sh
```

删除 LaunchAgent 和运行副本：

```bash
rm -f "$HOME/Library/LaunchAgents/com.local.mac-heat-app-monitor.plist"
rm -f "$HOME/Library/LaunchAgents/com.local.mac-heat-dashboard.plist"
rm -rf "$HOME/Library/Application Support/mac-heat-app-monitor"
```

如果你也想删除历史日志：

```bash
rm -rf "$HOME/Library/Logs/mac-heat-app-monitor"
```

## 排错

查看 dashboard 状态：

```bash
./mac-heat-dashboard.sh status
```

查看 monitor 状态：

```bash
./monitor-mac-heat-apps.sh status
```

查看 dashboard 日志：

```bash
./mac-heat-dashboard.sh tail
```

查看 monitor 日志：

```bash
./monitor-mac-heat-apps.sh tail
```

检查 LaunchAgent：

```bash
launchctl print "gui/$(id -u)/com.local.mac-heat-app-monitor"
launchctl print "gui/$(id -u)/com.local.mac-heat-dashboard"
```

端口被占用时，换一个端口：

```bash
./mac-heat-dashboard.sh start --port 8766 --open
```

页面打开但没有数据时：

- 先运行 `./monitor-mac-heat-apps.sh status`。
- 确认 `samples.tsv` 在增长。
- 确认 dashboard 和 monitor 使用同一个 log dir。
- 等待一个采样间隔后刷新页面。

浏览器标签图标没有变化时，关闭标签重新打开。favicon 可能会被浏览器缓存。

## 隐私和安全

- Dashboard 默认只监听 `127.0.0.1`，不对局域网开放。
- 日志会包含 App 名称、已脱敏的进程标签、电池状态和系统负载。
- 不要把自己的 `~/Library/Logs/mac-heat-app-monitor` 日志提交到公开仓库。
- 如果把 `--host` 改成 `0.0.0.0`，dashboard 可能被同一网络的其他设备访问，请自行配置防火墙和访问控制。

## 开发和验证

Shell 语法检查：

```bash
bash -n *.sh
```

Python 语法检查：

```bash
python3 -m py_compile mac-heat-dashboard-server.py
```

手动启动临时 dashboard：

```bash
python3 mac-heat-dashboard-server.py \
  --host 127.0.0.1 \
  --port 8766 \
  --samples /tmp/mac-heat-samples.tsv \
  --summary-log /tmp/mac-heat-summary.log \
  --error-log /tmp/mac-heat-error.log \
  --dashboard-pid-file /tmp/mac-heat-dashboard.pid
```

打开：

```text
http://127.0.0.1:8766
```

## License

MIT
