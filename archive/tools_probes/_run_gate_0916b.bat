@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
set G=D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe
%G% --headless --path . -s res://tools/verify_batch.gd -- res://_staged_levels/harvest_0916b > _staged_levels\gate_0916b.log 2>&1
echo GATE_0916B_DONE >> _staged_levels\gate_0916b.log
