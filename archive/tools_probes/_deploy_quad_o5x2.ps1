# Deploy quad-tier upgrade + o5x re-run (intro recovery + 5-7x entry-tier). ASCII only.
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output '=== push quad-tier files ==='
& $py tools\_cvm_push.py "core\difficulty.gd" /root/minesweeper/core/difficulty.gd 2>&1 | Select-Object -Last 1
& $py tools\_cvm_push.py "tools\batch_all_variants.gd" /root/minesweeper/tools/batch_all_variants.gd 2>&1 | Select-Object -Last 1
& $py tools\_cvm_push.py "tools\batch_audit_r07.gd" /root/minesweeper/tools/batch_audit_r07.gd 2>&1 | Select-Object -Last 1
& $py tools\_cvm_push.py "tools\batch_merge.gd" /root/minesweeper/tools/batch_merge.gd 2>&1 | Select-Object -Last 1
& $py tools\_cvm_push.py "tools\report_merge.gd" /root/minesweeper/tools/report_merge.gd 2>&1 | Select-Object -Last 1
$remote = @'
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
export GODOT_SILENCE_ROOT_WARNING=1
$G --headless --path . --import > /root/import_quad.log 2>&1
echo IMPORT_EXIT=$?
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o5x 10 400 -1 1 1 0 0 "o5x@5-9" "o5_xiemai" 30 > /root/gen_o5x2.log 2>&1 &
sleep 30
echo '=== procs ==='
pgrep -fc batch_all_variants
echo '=== log tail ==='
tail -8 /root/gen_o5x2.log
echo QUAD_O5X2_DONE
'@
Set-Content -Path "$env:TEMP\_remote_quad_o5x2.sh" -Value $remote -Encoding ASCII
& $py tools\_cvm_tat.py runfile "$env:TEMP\_remote_quad_o5x2.sh" 300
Write-Output '=== quad deploy finished ==='
