#!/bin/bash
# 启动 O9 量产（o9@5-9；per_tier=50 tiered stall=30——对齐 O8 参数）
export HOME=/root
cd /root/minesweeper
rm -f /root/gen_o9.log
setsid nohup /opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64 --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o9 10 400 -1 1 1 0 0 o9@5-9 o9_sheju 50 3000 tiered 30 > /root/gen_o9.log 2>&1 &
sleep 25
echo '=== proc count ==='
pgrep -fc batch_all_variants
echo '=== log head ==='
head -30 /root/gen_o9.log
echo LAUNCH_O9_DONE
