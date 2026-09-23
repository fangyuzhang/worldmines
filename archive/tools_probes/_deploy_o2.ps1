# Deploy O2 production on server: push v5 batch + o2 mod, stop 9x9 trial, launch o2@5-7 + o2@8. ASCII only.
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output '=== push batch v5 (timeout coef param) ==='
& $py tools\_cvm_push.py "tools\batch_all_variants.gd" /root/minesweeper/tools/batch_all_variants.gd
Write-Output '=== mkdir + push o2 mod ==='
& $py tools\_cvm_tat.py run "mkdir -p /root/minesweeper/demo/mods/o2_linxu && echo MK_OK" --timeout 60
& $py tools\_cvm_push.py "demo\mods\o2_linxu\entry.gd" /root/minesweeper/demo/mods/o2_linxu/entry.gd
& $py tools\_cvm_push.py "demo\mods\o2_linxu\manifest.json" /root/minesweeper/demo/mods/o2_linxu/manifest.json
$remote = @'
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
export GODOT_SILENCE_ROOT_WARNING=1
echo '=== stop 9x9 trial (artifacts kept) ==='
pkill -f "user://batch_o1_9" 2>/dev/null
sleep 3
echo '=== launch O2 production ==='
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o2_57 10 800 -1 1 1 0 0 "o2@5-7" "o2_linxu" 100 3000 > /root/gen_o2_57.log 2>&1 &
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o2_8 10 300 -1 1 1 0 0 "o2@8" "o2_linxu" 100 6000 > /root/gen_o2_8.log 2>&1 &
sleep 25
echo "=== procs (expect 2) ==="
pgrep -af "batch_all_variants" | head -4
echo "=== log57 tail ==="
tail -4 /root/gen_o2_57.log 2>/dev/null
echo "=== log8 tail ==="
tail -4 /root/gen_o2_8.log 2>/dev/null
echo O2_LAUNCH_DONE
'@
Set-Content -Path "$env:TEMP\_remote_o2_launch.sh" -Value $remote -Encoding ASCII
& $py tools\_cvm_tat.py runfile "$env:TEMP\_remote_o2_launch.sh" 200
Write-Output '=== o2 deploy finished ==='
