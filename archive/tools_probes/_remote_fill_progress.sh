#!/bin/bash
# 补产进度：日志尾部 + 已产关卡数（按档/尺寸）+ 进程状态
B=/root/.local/share/godot/app_userdata/wm_server/fill_v41_s1_hard
echo "=== 日志 ==="
tail -6 /root/fill_s1_hard.log
echo "=== 已产关卡（按尺寸/档）==="
for d in "$B"/classic_s1/*x*; do
  [ -d "$d" ] || continue
  printf "  %s: %s\n" "$(basename "$d")" "$(find "$d" -name '*.json' | wc -l)"
done
echo "  （合计 $(find "$B" -name '*.json' 2>/dev/null | wc -l)）"
echo "=== 进程 ==="
ps -eo pid,etime,pcpu,comm | grep -i godot | head -3
echo "=== 负载 ==="
uptime
echo FILL_PROGRESS_DONE
