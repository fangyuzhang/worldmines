# 切换服务器 O2 任务到提速版代码（推 rule_builder + o2 entry，续跑）——ASCII only
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output '=== push perf code ==='
& $py tools\_cvm_push.py "core\rule_builder.gd" /root/minesweeper/core/rule_builder.gd
& $py tools\_cvm_push.py "demo\mods\o2_linxu\entry.gd" /root/minesweeper/demo/mods/o2_linxu/entry.gd
$remote = @'
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
export GODOT_SILENCE_ROOT_WARNING=1
echo '=== import refresh ==='
$G --headless --path . --import > /root/import_perf.log 2>&1
echo IMPORT_EXIT=$?
echo '=== stop old o2 tasks (resume-safe) ==='
pkill -f "user://batch_o2_" 2>/dev/null
sleep 3
echo '=== relaunch with perf code (resume existing artifacts) ==='
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o2_57 10 800 -1 1 1 0 0 "o2@5-7" "o2_linxu" 100 3000 > /root/gen_o2_57.log 2>&1 &
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o2_8 10 300 -1 1 1 0 0 "o2@8" "o2_linxu" 100 6000 > /root/gen_o2_8.log 2>&1 &
sleep 30
echo '=== procs ==='
pgrep -fc batch_all_variants
echo '=== logs ==='
tail -2 /root/gen_o2_57.log
tail -2 /root/gen_o2_8.log
echo RESTART_O2_V2_DONE
'@
Set-Content -Path "$env:TEMP\_remote_restart_o2.sh" -Value $remote -Encoding ASCII
& $py tools\_cvm_tat.py runfile "$env:TEMP\_remote_restart_o2.sh" 300
Write-Output '=== restart done ==='
