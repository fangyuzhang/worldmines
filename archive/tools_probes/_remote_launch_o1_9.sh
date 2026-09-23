#!/bin/bash
# 启动 O1 9x9 试产（填充空闲核 + 收集 P04 性能数据）
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
export GODOT_SILENCE_ROOT_WARNING=1
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o1_9 10 3000 -1 1 1 0 0 "o1@9" "o1_duichuan" 100 > /root/gen_o1_9.log 2>&1 &
sleep 15
echo "=== procs (should be 2: o1_8 + o1_9) ==="
pgrep -af "batch_all_variants" | head -4
echo "=== log9 head ==="
head -8 /root/gen_o1_9.log 2>/dev/null
echo LAUNCH9_DONE
