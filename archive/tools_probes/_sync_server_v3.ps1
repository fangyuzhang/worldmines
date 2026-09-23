# Sync v3.0 files to server (O1 mod + batch tool with extra-combo support) - ASCII only
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
Write-Output '=== mkdir remote dir ==='
& $py tools\_cvm_tat.py run "mkdir -p /root/minesweeper/demo/mods/o1_duichuan && echo MKDIR_OK" --timeout 60
Write-Output '=== push batch_all_variants.gd ==='
& $py tools\_cvm_push.py "tools\batch_all_variants.gd" /root/minesweeper/tools/batch_all_variants.gd
Write-Output '=== push op_design_precheck.gd ==='
& $py tools\_cvm_push.py "tools\op_design_precheck.gd" /root/minesweeper/tools/op_design_precheck.gd
Write-Output '=== push o1 mod ==='
& $py tools\_cvm_push.py "demo\mods\o1_duichuan\entry.gd" /root/minesweeper/demo/mods/o1_duichuan/entry.gd
& $py tools\_cvm_push.py "demo\mods\o1_duichuan\manifest.json" /root/minesweeper/demo/mods/o1_duichuan/manifest.json
Write-Output '=== verify on server ==='
& $py tools\_cvm_tat.py run "md5sum /root/minesweeper/tools/batch_all_variants.gd /root/minesweeper/demo/mods/o1_duichuan/entry.gd | cut -c1-40; echo SYNC_V3_OK" --timeout 60
