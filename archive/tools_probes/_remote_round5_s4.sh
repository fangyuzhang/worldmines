#!/bin/bash
# 第五轮：S4「洋葱」量产（总表 20 集：5×5~9×9 × 4 档，各 100 关 = 2,000 关）。
# 排队：等前序轮次（A/B 路 + C/D/E 守护）全部结束后启动。
# 组合规格：classic + s4（S4 是全局约束类，需配底座线索——总表口径「洋葱（底座：经典）」）。
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
rm -f /root/gen_gap_F.log
setsid nohup bash -c "
while pgrep -f 'batch_all_variants' > /dev/null; do sleep 300; done
echo '前序轮次已结束，启动第五轮 S4' \$(date)
cd /root/minesweeper
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_s4 10 1200 -1 1 1 0 0 classic+s4@5-9 s4_yangcong 100 3000 tiered 30
echo ROAD_F_DONE
" > /root/gen_gap_F.log 2>&1 &
sleep 3
echo '=== 守护已挂 ==='
pgrep -af batch_all_variants | head -2 | cut -c1-80
echo '=== S4 mod 检查 ==='
ls /root/minesweeper/demo/mods/s4_yangcong/
echo ROUND5_SETUP_DONE
