#!/bin/bash
# 启动首发补产：s1 噩梦档（峰值 6-20）@7-9×7-9 —— 用服务器空闲核，严格按 v4.1 窗口
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
LOG=/root/fill_s1_hard.log
# 先确认工具在位（防静默跑空）
if [ ! -f tools/fill_window.gd ]; then
  echo "ERROR: tools/fill_window.gd 不在位"; exit 1
fi
nohup "$G" --headless --path . -s res://tools/fill_window.gd -- \
  classic s1 7,8,9 6 20 100 3000 7200 s1_jinxing user://fill_v41_s1_hard > "$LOG" 2>&1 &
sleep 25
echo "=== 启动确认（进程）==="
ps -eo pid,etime,pcpu,comm | grep -i godot | head -4
echo "=== 日志尾部 ==="
tail -6 "$LOG"
echo LAUNCH_DONE
