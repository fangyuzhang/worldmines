# Push stage-stats files to server (ASCII only)
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output '=== push puzzle_generator.gd ==='
& $py tools\_cvm_push.py "core\puzzle_generator.gd" /root/minesweeper/core/puzzle_generator.gd
Write-Output '=== push batch_all_variants.gd ==='
& $py tools\_cvm_push.py "tools\batch_all_variants.gd" /root/minesweeper/tools/batch_all_variants.gd
