# Run difficulty-unreachable precheck validation (ASCII only)
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$gd = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
& $gd --headless --path . --import *> $null
& $gd --headless --path . -s res://tools/_test_diff_unreach.gd 2>&1 | Select-String -Pattern "precheck|SCRIPT ERROR|Invalid" | Select-Object -First 10
& $gd --headless --path . -s res://tools/_test_diff_unreach.gd 2>&1 | Select-String -Pattern ":" | Select-Object -Last 8
