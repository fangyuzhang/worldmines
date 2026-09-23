#!/bin/bash
# 第十四轮：S7「分量数 K」量产（总表 20 集 × 100 关 = 2,000 关目标）——22 席收官。
# 排队：等前序轮次（A/B 路 + C~S5 守护）全部结束后启动。
# 注：S7 复用 S3 的父指针+层级机制（约 800 aux），生成慢（实测 8×8 81s / 9×9 100s），
#     故 timeout_coef 上调至 6000、seed_max 放宽至 2500。
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
rm -f /root/gen_gap_S7.log
setsid nohup bash -c "
while pgrep -f 'batch_all_variants' > /dev/null; do sleep 300; done
echo '前序轮次已结束，启动第十四轮 S7 分量数K' \$(date)
cd /root/minesweeper
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_s7 10 2500 -1 1 1 0 0 classic+s7@5-9 s7_fenliang 100 6000 tiered 30
echo ROAD_S7_DONE
" > /root/gen_gap_S7.log 2>&1 &
sleep 3
echo '=== 守护已挂 ==='
pgrep -af batch_all_variants | head -2 | cut -c1-80
echo '=== S7 mod 检查 ==='
ls /root/minesweeper/demo/mods/s7_fenliang/
echo ROUND12_SETUP_DONE
