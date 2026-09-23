#!/bin/bash
# 第三轮：S1「局部禁形」量产（总表 20 集：5×5~9×9 × 4 档，各 100 关 = 2,000 关）。
# 排队：等前两轮（A/B 路 + C 路守护）全部结束后启动。
# 组合规格：classic + s1（S1 是全局约束类，需配底座线索——总表口径「局部禁形（底座：经典）」）。
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
rm -f /root/gen_gap_D.log
setsid nohup bash -c "
while pgrep -f 'batch_all_variants' > /dev/null; do sleep 300; done
echo '前序轮次已结束，启动第三轮 S1' \$(date)
cd /root/minesweeper
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_s1 10 1200 -1 1 1 0 0 classic+s1@5-9 s1_jinxing 100 3000 tiered 30
echo ROAD_D_DONE
" > /root/gen_gap_D.log 2>&1 &
sleep 3
echo '=== 守护已挂（等前序轮次结束）==='
echo '=== 当前进程 ==='
pgrep -af batch_all_variants | head -3 | cut -c1-100
echo ROUND3_SETUP_DONE
