# Deploy O1 mass production on server (per-tier mode, GDD 4.7 quota) - ASCII only
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output '=== push updated batch tool v4 (per_tier) ==='
& $py tools\_cvm_push.py "tools\batch_all_variants.gd" /root/minesweeper/tools/batch_all_variants.gd
Write-Output '=== launch O1 production: 7x7 and 8x8, 100 per tier, seed max 2000 ==='
$launch = @'
export HOME=/root
cd /root/minesweeper
rm -rf /root/.local/share/godot/app_userdata/wm_server/batch_o1_7 /root/.local/share/godot/app_userdata/wm_server/batch_o1_8
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
export GODOT_SILENCE_ROOT_WARNING=1
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o1_7 10 3000 -1 1 1 0 0 "o1@7" "o1_duichuan" 100 > /root/gen_o1_7.log 2>&1 &
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o1_8 10 3000 -1 1 1 0 0 "o1@8" "o1_duichuan" 100 > /root/gen_o1_8.log 2>&1 &
sleep 20
echo "=== processes ==="
pgrep -af "batch_all_variants" | head -4
echo "=== logs head ==="
head -12 /root/gen_o1_7.log 2>/dev/null
echo "=== log8 head ==="
head -12 /root/gen_o1_8.log 2>/dev/null
echo LAUNCH_DONE
'@
Set-Content -Path "$env:TEMP\_remote_o1_launch.sh" -Value $launch -Encoding ASCII
& $py tools\_cvm_tat.py runfile "$env:TEMP\_remote_o1_launch.sh" 300
Write-Output '=== sync done ==='
