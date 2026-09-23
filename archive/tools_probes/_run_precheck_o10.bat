@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/op_design_precheck.gd -- o10 > _staged_levels\precheck_o10.log 2>&1
echo PRECHECK_O10_DONE >> _staged_levels\precheck_o10.log
