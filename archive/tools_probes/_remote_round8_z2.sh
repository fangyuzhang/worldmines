#!/bin/bash
# 第八轮：Z2「相邻行锁」量产（总表 20 集 × 100 关 = 2,000 关目标）。
# 排队：等前序轮次（A/B 路 + C~H 守护）全部结束后启动。
# 组合规格：classic + z2（Z2 是全局约束类，需配底座线索——总表口径「相邻行锁（底座：经典）」）。
# 注：Z2 有奇偶性要求（6×6 标准 14 雷不可满足）——产线的候选雷数回退机制会自动换值，
#     日志中的 mines_fallback 字段即为回退计数（合法）。
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
rm -f /root/gen_gap_I.log
setsid nohup bash -c "
while pgrep -f 'batch_all_variants' > /dev/null; do sleep 300; done
echo '前序轮次已结束，启动第八轮 Z2' \$(date)
cd /root/minesweeper
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_z2 10 1500 -1 1 1 0 0 classic+z2@5-9 z2_xianglin 100 4000 tiered 30
echo ROAD_I_DONE
" > /root/gen_gap_I.log 2>&1 &
sleep 3
echo '=== 守护已挂 ==='
pgrep -af batch_all_variants | head -2 | cut -c1-80
echo '=== Z2 mod 检查 ==='
ls /root/minesweeper/demo/mods/z2_xianglin/
echo ROUND8_SETUP_DONE
