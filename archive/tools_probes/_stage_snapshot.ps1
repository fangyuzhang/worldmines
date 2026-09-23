# Run variant snapshot into staging dir (ASCII only)
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$gd = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
$stage = "C:\Users\zjh30\CodeBuddy\20260906184916\_staged_levels"
& $gd --headless --path . -s res://tools/_variant_snapshot.gd -- "$stage\variant_snapshot_20260914.json" 2>&1 | Select-String -Pattern "snapshot" | Select-Object -First 2
Get-Content "$stage\variant_snapshot_20260914.json" -Encoding UTF8 | Select-Object -First 8
