#!/bin/bash
# O1 量产进度 + CPU 诊断
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server
echo '=== date ==='
date '+%F %T'
echo '=== uptime/load ==='
uptime
echo '=== procs ==='
pgrep -af batch_all_variants | head -4
echo '=== ps top cpu (time snapshot) ==='
ps -eo pid,pcpu,pmem,etime,args --sort=-pcpu 2>/dev/null | grep -E 'Godot' | grep -v grep | head -4
echo '=== top sample 1 ==='
top -bn1 | head -7
sleep 6
echo '=== top sample 2 (6s later) ==='
top -bn1 | head -7
echo '=== files count (total) ==='
echo -n "7x7: "; find $B/batch_o1_7 -name '*.json' 2>/dev/null | wc -l
echo -n "8x8: "; find $B/batch_o1_8 -name '*.json' 2>/dev/null | wc -l
echo '=== tier breakdown 7x7 ==='
for t in easy normal hard; do printf '%s: ' "$t"; find $B/batch_o1_7 -name "$t*.json" 2>/dev/null | wc -l; done
echo '=== tier breakdown 8x8 ==='
for t in easy normal hard; do printf '%s: ' "$t"; find $B/batch_o1_8 -name "$t*.json" 2>/dev/null | wc -l; done
echo '=== issues tails (unit_done heartbeat) ==='
tail -1 $B/batch_o1_7/issues.jsonl 2>/dev/null || echo '(7x7 no issues yet)'
tail -1 $B/batch_o1_8/issues.jsonl 2>/dev/null || echo '(8x8 no issues yet)'
echo '=== log tails ==='
tail -4 /root/gen_o1_7.log 2>/dev/null
echo '---'
tail -4 /root/gen_o1_8.log 2>/dev/null
echo '=== nproc ==='
nproc
echo CHECK2_DONE
