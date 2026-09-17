@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/_probe_hidden_state.gd > _staged_levels\hs_probe.log 2>&1
echo HS_PROBE_DONE >> _staged_levels\hs_probe.log
