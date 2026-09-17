@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_o10_huanyou.gd -gexit > _staged_levels\gut_o10.log 2>&1
echo GUT_O10_DONE >> _staged_levels\gut_o10.log
