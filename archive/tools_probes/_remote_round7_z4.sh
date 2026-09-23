#!/bin/bash
# 第七轮：Z4「行列同序」量产（总表 9 集 × 100 关 = 900 关；跑 5×5~9×9 × 4 档，超出部分自然不产）。
# 排队：等前序轮次（A/B 路 + C~G 守护）全部结束后启动。
# 组合规格：classic + z4（Z4 是全局约束类，需配底座线索——总表口径「行列同序（底座：经典）」）。
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
rm -f /root/gen_gap_H.log
setsid nohup bash -c "
while pgrep -f 'batch_all_variants' > /dev/null; do sleep 300; done
echo '前序轮次已结束，启动第七轮 Z4' \$(date)
cd /root/minesweeper
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_z4 10 1200 -1 1 1 0 0 classic+z4@5-9 z4_hangliesu 100 3500 tiered 30
echo ROAD_H_DONE
" > /root/gen_gap_H.log 2>&1 &
sleep 3
echo '=== 守护已挂 ==='
pgrep -af batch_all_variants | head -2 | cut -c1-80
echo '=== Z4 mod 检查 ==='
ls /root/minesweeper/demo/mods/z4_hangliesu/
echo ROUND7_SETUP_DONE
