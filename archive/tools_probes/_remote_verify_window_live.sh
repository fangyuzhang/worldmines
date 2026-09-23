#!/bin/bash
# 核实窗口能力已在服务器生效：①源码在位 ②判据三档 ③坏格式 fail-fast（证明新解析在跑）
cd /root/minesweeper
echo "=== 源码在位 ==="
grep -c "_peak_window" tools/batch_all_variants.gd
grep -n -A5 "const PEAK_WINDOWS" core/difficulty.gd | head -7
ls -la tools/run_window_production.sh | awk '{print $5, $9}'
echo "=== fail-fast 冒烟：坏窗口格式 \"9\" 应 exit=1 ==="
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
"$G" --headless --path . -s res://tools/batch_all_variants.gd -- user://_win_probe 1 2 -1 1 1 1 0 "classic@5" "" 1 3000 off 60 -1 "9" 2>&1 | tail -3
echo "exit=$?"
echo "=== 启动器语法检查 ==="
bash -n tools/run_window_production.sh && echo "bash -n OK"
echo VERIFY_DONE
