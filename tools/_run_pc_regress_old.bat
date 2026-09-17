@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
set G=D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe
%G% --headless --path . -s res://tools/op_design_precheck.gd -- o1 3 > _staged_levels\pc_old_o1.log 2>&1
%G% --headless --path . -s res://tools/op_design_precheck.gd -- o3 3 > _staged_levels\pc_old_o3.log 2>&1
%G% --headless --path . -s res://tools/op_design_precheck.gd -- o9 3 > _staged_levels\pc_old_o9.log 2>&1
%G% --headless --path . -s res://tools/op_design_precheck.gd -- o10 3 > _staged_levels\pc_old_o10.log 2>&1
echo DONE_OLD >> _staged_levels\pc_old_o1.log
