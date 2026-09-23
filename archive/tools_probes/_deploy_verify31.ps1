# Deploy verify_batch v3.1 and rerun final verify (ASCII only)
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output '=== kill buggy verify run ==='
& $py tools\_cvm_tat.py run "pkill -f verify_batch.gd; pkill -f 'final_verify.sh'; sleep 1; pgrep -fc verify_batch || echo 0" --timeout 60
Write-Output '=== push verify_batch.gd ==='
& $py tools\_cvm_push.py "tools\verify_batch.gd" /root/minesweeper/tools/verify_batch.gd
Write-Output '=== relaunch final verify (bg) ==='
& $py tools\_cvm_tat.py runfile tools\_remote_final_verify.sh 28800 --bg
