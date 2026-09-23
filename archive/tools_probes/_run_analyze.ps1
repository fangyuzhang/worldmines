# Run O1 analysis in background, capture to file, wait, then show
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$g = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
Remove-Item "$env:TEMP\o1a.log" -ErrorAction SilentlyContinue
Start-Process -FilePath $g -ArgumentList "--headless", "--path", ".", "-s", "res://tools/_analyze_o1.gd" -NoNewWindow -RedirectStandardOutput "$env:TEMP\o1a.log"
Write-Output "started, waiting 100s..."
Start-Sleep -Seconds 100
Write-Output "=== log content ==="
Get-Content "$env:TEMP\o1a.log" -ErrorAction SilentlyContinue | Select-Object -First 60
Write-Output "=== still running? ==="
Get-Process -Name "*Godot*" -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, CPU | Format-Table -AutoSize
