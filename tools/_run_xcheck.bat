@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
echo === step1: generate xcheck levels ===
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/_xcheck_gen.gd > _staged_levels\xcheck_gen.log 2>&1
echo === step2: independent gate (verify_batch) ===
"D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/verify_batch.gd -- res://_staged_levels/xcheck > _staged_levels\xcheck_gate.log 2>&1
echo DONE
