@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
set G=D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe
%G% --headless --path . -s res://tools/verify_batch.gd -- res://_staged_levels/harvest_0917/batch_o9 > _staged_levels\gate_0917_o9.log 2>&1
%G% --headless --path . -s res://tools/verify_batch.gd -- res://_staged_levels/harvest_0917/batch_o5x > _staged_levels\gate_0917_o5x.log 2>&1
%G% --headless --path . -s res://tools/verify_batch.gd -- res://_staged_levels/harvest_0917/batch_o10 > _staged_levels\gate_0917_o10.log 2>&1
%G% --headless --path . -s res://tools/verify_batch.gd -- res://_staged_levels/harvest_0917/batch_o8 > _staged_levels\gate_0917_o8.log 2>&1
echo GATE_ALL_DONE >> _staged_levels\gate_0917_o9.log
