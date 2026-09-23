@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
set G=D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe
rmdir /s /q "%APPDATA%\Godot\app_userdata\世界扫雷 (Copy)\policy_check2" 2>nul
%G% --headless --path . -s res://tools/batch_all_variants.gd -- user://policy_check2 1 2 -1 0 1 1 0 classic+z1@5-9 z1_jingxiang 1 3000 tiered 30 > _staged_levels\smoke_policy.log 2>&1
echo SMOKE_DONE >> _staged_levels\smoke_policy.log
