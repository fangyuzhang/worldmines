@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/unit -gexit > _staged_levels\gut_full.log 2>&1
echo GUT_FULL_DONE >> _staged_levels\gut_full.log
