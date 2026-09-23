#!/bin/bash
# O3 分档·生产启动（7x7 + 8x8，per_tier=100）
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
export GODOT_SILENCE_ROOT_WARNING=1
rm -rf /root/.local/share/godot/app_userdata/wm_server/batch_o3
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o3 10 400 -1 1 1 0 0 "o3@7-8" "o3_fendang" 100 > /root/gen_o3.log 2>&1 &
sleep 20
echo "=== procs (now 5: o2x2 + o1bx2 + o3) ==="
pgrep -fc batch_all_variants
echo "=== log o3 ==="
tail -4 /root/gen_o3.log 2>/dev/null
echo O3_LAUNCH_DONE
