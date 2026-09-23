# Push 9-14 code updates to server, verify, then relaunch O1 production. ASCII only.
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output '=== push updated files ==='
& $py tools\_cvm_push.py "core\puzzle_generator.gd" /root/minesweeper/core/puzzle_generator.gd
& $py tools\_cvm_push.py "core\rule_feasibility.gd" /root/minesweeper/core/rule_feasibility.gd
& $py tools\_cvm_push.py "tools\mod_selfcheck.gd" /root/minesweeper/tools/mod_selfcheck.gd
& $py tools\_cvm_push.py "tools\verify_batch.gd" /root/minesweeper/tools/verify_batch.gd
$remote = @'
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
echo '=== import refresh ==='
$G --headless --path . --import > /root/import_v4.log 2>&1
echo IMPORT_EXIT=$?
echo '=== front test (o1@7, per_tier 2) ==='
timeout 240 $G --headless --path . -s res://tools/batch_all_variants.gd -- user://_diag2 1 30 -1 1 1 0 0 "o1@7" "o1_duichuan" 2 2>&1 | tail -20
echo FRONT_DONE
'@
Set-Content -Path "$env:TEMP\_remote_v4_retry.sh" -Value $remote -Encoding ASCII
& $py tools\_cvm_tat.py runfile "$env:TEMP\_remote_v4_retry.sh" 400
Write-Output '=== v2 deploy script finished ==='
