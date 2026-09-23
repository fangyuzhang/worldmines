#!/bin/bash
R=/root/minesweeper
echo "=== o6/o7 mod 是否在服务器 ==="
for m in o6_redu o7_qixian; do
  [ -f "$R/demo/mods/$m/entry.gd" ] && echo "OK      $m" || echo "MISSING $m"
done
echo "=== 主链是否已结束（判据文件）==="
tail -2 /root/gen_chain_main.log 2>/dev/null
echo "=== 当前 Godot 进程 ==="
ps -eo pid,etime,comm= | grep Godot | cut -c1-46
echo "=== 现有补批脚本？==="
ls -l /root/gap_chain*.sh 2>/dev/null
echo "=== batch_all（旧变体残留）大小 ==="
du -sh /root/.local/share/godot/app_userdata/wm_server/batch_all 2>/dev/null
