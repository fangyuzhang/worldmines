# Push verify_batch v3 + watchdog v3 to server (ASCII only)
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output '=== push verify_batch.gd ==='
& $py tools\_cvm_push.py "tools\verify_batch.gd" /root/minesweeper/tools/verify_batch.gd
Write-Output '=== push watchdog v3 + restart service ==='
& $py tools\_cvm_push.py "tools\_remote_watchdog.sh" /root/watchdog.sh
& $py tools\_cvm_tat.py run "systemctl restart wm-gen-watchdog; sleep 2; systemctl is-active wm-gen-watchdog; pgrep -fc batch_all_variants; echo V3_DEPLOYED" --timeout 60
