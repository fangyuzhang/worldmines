#!/bin/bash
# 第九~十一轮：Z1「镜像」→ Z3「四象」→ Z5「等差行」量产（守恒轴收尾三席）。
# 排队：等前序轮次（A/B 路 + C~I 守护）全部结束后依次启动。
# 组合规格：classic + zN（守恒轴均为全局约束类，需配底座线索）。
# 注：Z3/Z5 有 GDD 明示的整除/判别式要求（6×6 需 4 的倍数、7×7 需 7 的倍数等），
#     产线的候选雷数回退机制会自动换值（日志 mines_fallback 计数为合法）。
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
rm -f /root/gen_gap_Z.log
setsid nohup bash -c "
while pgrep -f 'batch_all_variants' > /dev/null; do sleep 300; done
echo '前序轮次已结束，启动守恒轴收尾三席' \$(date)
cd /root/minesweeper
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_z1 10 1200 -1 1 1 0 0 classic+z1@5-9 z1_jingxiang 100 3500 tiered 30
echo Z1_DONE
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_z3 10 1500 -1 1 1 0 0 classic+z3@5-9 z3_sixiang 100 3500 tiered 30
echo Z3_DONE
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_z5 10 1500 -1 1 1 0 0 classic+z5@5-9 z5_dengcha 100 3500 tiered 30
echo ROAD_Z_DONE
" > /root/gen_gap_Z.log 2>&1 &
sleep 3
echo '=== 守护已挂 ==='
pgrep -af batch_all_variants | head -2 | cut -c1-80
echo '=== Z1/Z3/Z5 mod 检查 ==='
for m in z1_jingxiang z3_sixiang z5_dengcha; do echo "-- $m"; ls /root/minesweeper/demo/mods/$m/ 2>&1; done
echo ROUND9_SETUP_DONE
