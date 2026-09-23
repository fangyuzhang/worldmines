#!/bin/bash
# 利用率 + 任务进度/速率 深查（用于估算剩余时间与流水线设计）
export HOME=/root
echo '=== date ==='
date
echo '=== cpu (vmstat 3s) ==='
vmstat 1 3
echo '=== load ==='
uptime
echo '=== jobs ==='
ps -eo pid,pcpu,etime,cmd --sort=-pcpu | grep batch_all_variants | grep -v grep
echo '=== progress & units ==='
B=/root/.local/share/godot/app_userdata/wm_server
for j in o9 o10; do
  echo "--- $j ---"
  echo "json=$(find $B/batch_$j -name '*.json' 2>/dev/null | wc -l)"
  echo "unit_done=$(grep -c unit_done $B/batch_$j/issues.jsonl 2>/dev/null)"
  grep unit_done $B/batch_$j/issues.jsonl 2>/dev/null | tail -3
done
echo '=== done? ==='
ls $B/batch_o9/all_report* $B/batch_o10/all_report* 2>/dev/null || echo 'no reports yet'
echo PIPELINE_CHECK_DONE
