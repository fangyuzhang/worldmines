@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
set G=D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe
%G% --headless --path . -s res://tools/op_design_precheck.gd -- o1 3 > _staged_levels\pc2_o1.log 2>&1
%G% --headless --path . -s res://tools/op_design_precheck.gd -- o3 3 > _staged_levels\pc2_o3.log 2>&1
%G% --headless --path . -s res://tools/op_design_precheck.gd -- o9 3 > _staged_levels\pc2_o9.log 2>&1
%G% --headless --path . -s res://tools/op_design_precheck.gd -- o10 3 > _staged_levels\pc2_o10.log 2>&1
%G% --headless --path . -s res://tools/op_design_precheck.gd -- o5x 3 > _staged_levels\pc2_o5x.log 2>&1
%G% --headless --path . -s res://tools/op_design_precheck.gd -- o5b 3 > _staged_levels\pc2_o5b.log 2>&1
echo DONE_RETEST >> _staged_levels\pc2_o1.log
