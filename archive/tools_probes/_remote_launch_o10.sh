#!/bin/bash
# 启动 O10 量产（与 O9 并行，目标双核吃满 ~95%）
export HOME=/root
cd /root/minesweeper
rm -f /root/gen_o10.log
setsid nohup /opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64 --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o10 10 400 -1 1 1 0 0 o10@5-9 o10_huanyou 50 3000 tiered 30 > /root/gen_o10.log 2>&1 &
sleep 30
echo '=== procs ==='
pgrep -fc batch_all_variants
echo '=== load ==='
uptime
echo '=== o10 log head ==='
head -25 /root/gen_o10.log
echo LAUNCH_O10_DONE
