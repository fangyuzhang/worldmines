@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/verify_batch.gd -- res://_staged_levels/harvest_0915b/batch_o4 > _staged_levels\verify_o4_after.log 2>&1
echo VERIFY_O4_AFTER_DONE >> _staged_levels\verify_o4_after.log
