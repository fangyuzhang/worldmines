#!/bin/bash
# 量化生成速度：O2 各任务产出 + 单关成本
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server
echo "=== now ==="
date '+%F %T'
echo "=== procs ==="
pgrep -fc batch_all_variants
echo "=== o2_57 ==="
find $B/batch_o2_57 -name '*.json' 2>/dev/null | wc -l
for t in easy normal hard; do printf '%s: ' "$t"; find $B/batch_o2_57 -name "$t*.json" 2>/dev/null | wc -l; done
echo "=== o2_8 ==="
find $B/batch_o2_8 -name '*.json' 2>/dev/null | wc -l
for t in easy normal hard; do printf '%s: ' "$t"; find $B/batch_o2_8 -name "$t*.json" 2>/dev/null | wc -l; done
echo "=== o2_57 unit_done (if any) ==="
tail -1 $B/batch_o2_57/issues.jsonl 2>/dev/null | cut -c1-260
echo "=== o2_8 unit_done (if any) ==="
tail -1 $B/batch_o2_8/issues.jsonl 2>/dev/null | cut -c1-260
echo "=== start times (proc etime) ==="
ps -eo pid,etime,args 2>/dev/null | grep batch_all_variants | grep -v grep | head -4 | cut -c1-90
echo "=== load ==="
uptime
echo SPEED_CHECK_DONE
