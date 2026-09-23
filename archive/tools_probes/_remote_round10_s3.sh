#!/bin/bash
# 第十二轮：S3「无环」量产（总表 20 集 × 100 关 = 2,000 关目标）。
# 排队：等前序轮次（A/B 路 + C~Z 守护）全部结束后启动。
# 注意：S3 的 CP-SAT 编码含 ~800 个 aux（层级/父指针），且 GDD 预警小盘可能欠产；
#       故 timeout_coef 上调至 6000、seed_max 放宽至 2000。
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
rm -f /root/gen_gap_S3.log
setsid nohup bash -c "
while pgrep -f 'batch_all_variants' > /dev/null; do sleep 300; done
echo '前序轮次已结束，启动第十二轮 S3 无环' \$(date)
cd /root/minesweeper
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_s3 10 2000 -1 1 1 0 0 classic+s3@5-9 s3_wuhuan 100 6000 tiered 30
echo ROAD_S3_DONE
" > /root/gen_gap_S3.log 2>&1 &
sleep 3
echo '=== 守护已挂 ==='
pgrep -af batch_all_variants | head -2 | cut -c1-80
echo '=== S3 mod 检查 ==='
ls /root/minesweeper/demo/mods/s3_wuhuan/
echo ROUND10_SETUP_DONE
