@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/batch_all_variants.gd -- user://o10_smoke 3 40 -1 1 1 0 0 o10@5-9 o10_huanyou 2 3000 > _staged_levels\o10_smoke.log 2>&1
echo O10_SMOKE_DONE >> _staged_levels\o10_smoke.log
