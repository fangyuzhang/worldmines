#!/bin/bash
# 服务器状态检查（决定是否可插入窗口模式补产 lane C）
echo "=== 负载 ==="
uptime
echo "=== Godot 进程（按 CPU 排序）==="
ps -eo pid,comm,etime,pcpu --sort=-pcpu 2>/dev/null | grep -i godot | head -6
echo "=== 最近日志 ==="
ls -lt /root/*.log /root/minesweeper/*.log 2>/dev/null | head -6
echo "=== 链进度（尾部）==="
for f in $(ls -t /root/*.log /root/minesweeper/*.log 2>/dev/null | head -3); do
  echo "-- $f"
  tail -3 "$f"
done
echo "=== 产物总量（user:// json）==="
find /root/.local -name '*.json' -not -name '*report*' 2>/dev/null | wc -l
