#!/bin/bash
# 补产部署（P2，2026-09-16）：把「部分覆盖集」补到 100 关/档。
# 双路并发（服务器 2 核）：A = o10 → o5x → o4；B = o8 → o9。
# 要点：out_dir 指向**已有产物目录**（断点续跑：_scan_unit 按档计数，已满档不收）；
#       seed_start 取该批次历史 tried 最大值 + 缓冲（跳过已用 seed，避免重放白花时间）；
#       per_tier=100（目标满档）、tiered（朝档走）、stall=30（满档早停）。
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
rm -f /root/gen_gap_A.log /root/gen_gap_B.log

setsid nohup bash -c "
cd /root/minesweeper
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o10 10 1200 -1 1 1 410 0 o10@5-9 o10_huanyou 100 3000 tiered 30
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o5x 10 1200 -1 1 1 40 0 o5x@5-9 o5_xiemai 100 3000 tiered 30
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o4 10 1200 -1 1 1 410 0 o4@5-9 o4_bianjing 100 3000 tiered 30
echo ROAD_A_DONE
" > /root/gen_gap_A.log 2>&1 &

setsid nohup bash -c "
cd /root/minesweeper
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o8 10 1200 -1 1 1 360 0 o8@5-9 o8_zhongdian 100 3000 tiered 30
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o9 10 1200 -1 1 1 120 0 o9@5-9 o9_sheju 100 3000 tiered 30
echo ROAD_B_DONE
" > /root/gen_gap_B.log 2>&1 &

sleep 45
echo '=== proc count ==='
pgrep -fc batch_all_variants
echo '=== load ==='
uptime
echo '=== road A head ==='
head -25 /root/gen_gap_A.log
echo '=== road B head ==='
head -25 /root/gen_gap_B.log
echo LAUNCH_GAP_DONE
