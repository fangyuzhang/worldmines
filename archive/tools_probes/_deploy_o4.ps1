# Deploy O4 + platform extension: push files, launch o4@6-9. ASCII only.
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output '=== push platform files ==='
& $py tools\_cvm_push.py "core\rule_builder.gd" /root/minesweeper/core/rule_builder.gd 2>&1 | Select-Object -Last 1
& $py tools\_cvm_push.py "core\rule_plugin.gd" /root/minesweeper/core/rule_plugin.gd 2>&1 | Select-Object -Last 1
& $py tools\_cvm_push.py "core\rule_oracle.gd" /root/minesweeper/core/rule_oracle.gd 2>&1 | Select-Object -Last 1
Write-Output '=== push o4 mod ==='
& $py tools\_cvm_tat.py run "mkdir -p /root/minesweeper/demo/mods/o4_bianjing && echo MK_OK" --timeout 60 2>&1 | Select-Object -Last 1
& $py tools\_cvm_push.py "demo\mods\o4_bianjing\entry.gd" /root/minesweeper/demo/mods/o4_bianjing/entry.gd 2>&1 | Select-Object -Last 1
& $py tools\_cvm_push.py "demo\mods\o4_bianjing\manifest.json" /root/minesweeper/demo/mods/o4_bianjing/manifest.json 2>&1 | Select-Object -Last 1
$remote = @'
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
export GODOT_SILENCE_ROOT_WARNING=1
$G --headless --path . --import > /root/import_o4.log 2>&1
echo IMPORT_EXIT=$?
rm -rf /root/.local/share/godot/app_userdata/wm_server/batch_o4
nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o4 10 400 -1 1 1 0 0 "o4@6-9" "o4_bianjing" 100 > /root/gen_o4.log 2>&1 &
sleep 30
echo '=== procs (now 6) ==='
pgrep -fc batch_all_variants
echo '=== log o4 ==='
tail -5 /root/gen_o4.log
echo O4_LAUNCH_DONE
'@
Set-Content -Path "$env:TEMP\_remote_o4_launch.sh" -Value $remote -Encoding ASCII
& $py tools\_cvm_tat.py runfile "$env:TEMP\_remote_o4_launch.sh" 300
Write-Output '=== o4 deploy finished ==='
