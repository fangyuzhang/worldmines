@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
echo LAUNCHED - waiting 70s...
start /b "" "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/_analyze_o1.gd > %TEMP%\o1a.log 2>&1
timeout /t 70 /nobreak > nul
echo === LOG ===
type %TEMP%\o1a.log
echo === LOG_END ===
