#!/bin/bash
# 双任务稳态负载验证（目标 ~95%，留 5% 应急）
export HOME=/root
echo '=== procs ==='
ps -eo pid,pcpu,cmd --sort=-pcpu | grep batch_all_variants | grep -v grep
echo '=== load ==='
uptime
echo '=== vmstat 4s ==='
vmstat 1 4
echo '=== o9/o10 progress ==='
B=/root/.local/share/godot/app_userdata/wm_server
echo "o9=$(find $B/batch_o9 -name '*.json' 2>/dev/null | wc -l) o10=$(find $B/batch_o10 -name '*.json' 2>/dev/null | wc -l)"
echo LOAD_VERIFY_DONE
