#!/bin/bash
# 诊断 batch_all_variants.gd 服务器 parse error（前台跑一次看完整输出）
export HOME=/root
cd /root/minesweeper
echo '=== full log head (gen_o1_7.log) ==='
head -40 /root/gen_o1_7.log
echo '=== try run front (120s cap) ==='
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
timeout 120 $G --headless --path . -s res://tools/batch_all_variants.gd -- user://_diag 1 2 -1 1 1 0 0 "o1@7" "o1_duichuan" 1 2>&1 | head -60
echo '=== import cache check ==='
ls -la /root/minesweeper/.godot/global_script_class_cache.cfg 2>/dev/null
grep -c "batch_all_variants" /root/minesweeper/.godot/global_script_class_cache.cfg 2>/dev/null
echo DIAG_DONE
