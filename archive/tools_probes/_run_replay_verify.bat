@echo off
rem Batch replay verification: o5x then o4 (hidden-state replay recovery test).
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/_replay_verify.gd -- res://_staged_levels/harvest_0915b/batch_o5x > _staged_levels\replay_verify_o5x.log 2>&1
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/_replay_verify.gd -- res://_staged_levels/harvest_0915b/batch_o4 > _staged_levels\replay_verify_o4.log 2>&1
echo REPLAY_VERIFY_DONE > _staged_levels\replay_verify_done.txt
