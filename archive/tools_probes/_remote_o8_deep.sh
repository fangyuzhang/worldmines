#!/bin/bash
export HOME=/root
echo '=== procs ==='
ps -eo pid,etime,cmd | grep -E "batch_all_variants" | grep -v grep
echo '(empty = no gen proc)'
echo '=== gen_o8.log tail ==='
tail -12 /root/gen_o8.log 2>/dev/null
echo '=== o8 newest ==='
B=/root/.local/share/godot/app_userdata/wm_server/batch_o8
find "$B" -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -3
echo '=== report? ==='
ls "$B"/all_report* 2>/dev/null || echo none
echo '=== mem/load ==='
free -m | head -2
uptime
echo O8DEEP_DONE
