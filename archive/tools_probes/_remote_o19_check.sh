#!/bin/bash
# o1_9 残局判定：日志/目录/最新文件时间
export HOME=/root
echo '=== o1_9 logs ==='
ls -la /root/gen_o1_9* 2>/dev/null
ls -la /root/*o1_9* 2>/dev/null
echo '=== dir count ==='
B=/root/.local/share/godot/app_userdata/wm_server/batch_o1_9
find "$B" -name '*.json' 2>/dev/null | wc -l
echo '=== newest 3 ==='
find "$B" -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -3
echo '=== has report? ==='
ls "$B" 2>/dev/null | grep -E "report|issues" || echo none
echo O19CHECK_DONE
