@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe --headless --path . -s res://tools/_probe_user_args.gd -- user://policy_check 1 2 -1 0 1 1 0 0 classic+z1@5-9 z1_jingxiang 1 3000 tiered 30 > _staged_levels\probe_args.log 2>&1
echo PROBE_DONE >> _staged_levels\probe_args.log
