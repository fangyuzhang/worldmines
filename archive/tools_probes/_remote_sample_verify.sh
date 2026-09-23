#!/bin/bash
# 服务器：抽样门禁（最低产/最可疑组合），不跑全量以免与仍在跑的 shard 1 抢 CPU
export HOME=/root
export GODOT_SILENCE_ROOT_WARNING=1
GD=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
B=/root/.local/share/godot/app_userdata/wm_server/batch_all
cd /root/minesweeper
for combo in mx_ep mx_sc dt_4c mx_4c mx_rl; do
  if [ -d "$B/$combo" ]; then
    echo "########## $combo ##########"
    "$GD" --headless --path . -s res://tools/verify_batch.gd -- "user://batch_all/$combo" 2>&1 | grep -E "可解|难度分布|FAIL|VERIFY|clue_ratio" | head -8
  fi
done
echo SAMPLE_VERIFY_DONE
