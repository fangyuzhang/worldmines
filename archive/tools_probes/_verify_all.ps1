# _verify_all.ps1 —— seven-dir gate verify re-run (output captured to file)
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$G = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
$BASE = "C:/Users/zjh30/CodeBuddy/20260906184916/_staged_levels/harvest_0915"
foreach ($d in @('batch_o2_57','batch_o2_8','batch_o3','batch_o5x','batch_o1_9','batch_o1b_7','batch_o1b_8')) {
  Write-Output "===== $d ====="
  & $G --headless --path . -s res://tools/verify_batch.gd -- "$BASE/$d" 2>&1
  Write-Output "EXIT=$LASTEXITCODE"
}
Write-Output "ALL_DONE"
