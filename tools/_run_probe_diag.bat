@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/_probe_o5x_fail.gd -- res://_staged_levels/harvest_0915b/batch_o5x/x_o5x/9x9/intro_13.json res://_staged_levels/harvest_0915b/batch_o5x/x_o5x/8x8/easy_01.json > _staged_levels\probe_o5x_diag.log 2>&1
echo DIAG_DONE >> _staged_levels\probe_o5x_diag.log
