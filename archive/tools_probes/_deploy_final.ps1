# Push final-round fixes to server (ASCII only)
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output '=== push puzzle_generator.gd (SOLUTION_SAMPLES=7) ==='
& $py tools\_cvm_push.py "core\puzzle_generator.gd" /root/minesweeper/core/puzzle_generator.gd
Write-Output '=== push scan_errors.sh ==='
& $py tools\_cvm_push.py "tools\_remote_scan_errors.sh" /root/scan_errors.sh
Write-Output '=== push final_verify.sh ==='
& $py tools\_cvm_push.py "tools\_remote_final_verify.sh" /root/final_verify.sh
Write-Output '=== confirm running procs unaffected ==='
& $py tools\_cvm_tat.py run "pgrep -fc batch_all_variants; echo DEPLOY_FINAL_OK" --timeout 60
