#!/bin/bash
# 服务器进度细查：在跑进程 / 各目录完成标志 / 最近写入
export HOME=/root
echo '=== running procs ==='
ps -eo pid,etime,cmd | grep batch_all_variants | grep -v grep
echo '=== per-dir status ==='
B=/root/.local/share/godot/app_userdata/wm_server
for d in "$B"/batch_*; do
  [ -d "$d" ] || continue
  r=$(ls "$d"/all_report*.json 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ',')
  last=$(find "$d" -name '*.json' -mmin -15 2>/dev/null | wc -l)
  newest=$(find "$d" -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- | xargs -r basename)
  echo "$(basename $d): reports=[$r] new15min=$last newest=$newest"
done
echo '=== recent logs ==='
ls -lt /root/gen_*.log 2>/dev/null | head -6
echo '=== disk ==='
df -h / | tail -1
echo '=== done ==='
