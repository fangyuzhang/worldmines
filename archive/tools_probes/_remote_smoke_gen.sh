#!/bin/bash
# 服务器：验证 assembly_name + 冒烟生成（2 单元 × 2 seed）
export HOME=/root
cd /root/minesweeper
echo "=== assembly_name ==="
grep assembly_name project.godot
GD=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
echo "=== 冒烟生成 ==="
timeout 900 "$GD" --headless --path . -s res://tools/batch_all_variants.gd -- user://smoke 1 2 2 0 1 2>&1 | tail -30
echo "SMOKE_EXIT=$?"
echo "=== 产出 ==="
find /root/.local/share/godot/app_userdata -maxdepth 3 -name "*.json" -o -maxdepth 3 -name "*.jsonl" 2>/dev/null | head -10
echo SMOKE_DONE
