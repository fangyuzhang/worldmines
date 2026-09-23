# 推 watchdog v2 + 安装 systemd 自愈服务
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output "=== 推送 watchdog v2 ==="
& $py tools\_cvm_push.py "tools\_remote_watchdog.sh" /root/watchdog.sh
Write-Output "=== 安装 systemd 服务 ==="
& $py tools\_cvm_tat.py runfile tools\_remote_install_watchdog.sh 300
