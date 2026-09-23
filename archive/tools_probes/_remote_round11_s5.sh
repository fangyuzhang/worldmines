#!/bin/bash
# 第十三轮：S5「行列凸」量产（总表 20 集 × 100 关 = 2,000 关目标）。
# 排队：等前序轮次（A/B 路 + C~S3 守护）全部结束后启动。
# 注：S5 用保守编码（整盘行列连续 ⊂ 按块连续），编码无 aux、生成快。
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
rm -f /root/gen_gap_S5.log
setsid nohup bash -c "
while pgrep -f 'batch_all_variants' > /dev/null; do sleep 300; done
echo '前序轮次已结束，启动第十三轮 S5 行列凸' \$(date)
cd /root/minesweeper
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_s5 10 1200 -1 1 1 0 0 classic+s5@5-9 s5_hanglie 100 3500 tiered 30
echo ROAD_S5_DONE
" > /root/gen_gap_S5.log 2>&1 &
sleep 3
echo '=== 守护已挂 ==='
pgrep -af batch_all_variants | head -2 | cut -c1-80
echo '=== S5 mod 检查 ==='
ls /root/minesweeper/demo/mods/s5_hanglie/
echo ROUND11_SETUP_DONE
