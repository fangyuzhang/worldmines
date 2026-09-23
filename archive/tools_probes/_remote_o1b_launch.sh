#!/bin/bash
# O1 效率布雷·生产实测（补产 normal/hard——验证新布雷的服务器端接受率）
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
export GODOT_SILENCE_ROOT_WARNING=1
rm -rf /root/.local/share/godot/app_userdata/wm_server/batch_o1b_7 /root/.local/share/godot/app_userdata/wm_server/batch_o1b_8
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o1b_7 10 400 -1 1 1 0 0 "o1@7" "o1_duichuan" 100 > /root/gen_o1b_7.log 2>&1 &
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o1b_8 10 400 -1 1 1 0 0 "o1@8" "o1_duichuan" 100 > /root/gen_o1b_8.log 2>&1 &
sleep 25
echo "=== procs (expect 4: o2 x2 + o1b x2) ==="
pgrep -fc batch_all_variants
echo "=== log o1b_7 ==="
tail -3 /root/gen_o1b_7.log 2>/dev/null
echo "=== log o1b_8 ==="
tail -3 /root/gen_o1b_8.log 2>/dev/null
echo O1B_LAUNCH_DONE
