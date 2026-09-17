@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_hidden_state_roundtrip.gd -gexit > _staged_levels\gut_hs.log 2>&1
echo GUT_HS_DONE >> _staged_levels\gut_hs.log
