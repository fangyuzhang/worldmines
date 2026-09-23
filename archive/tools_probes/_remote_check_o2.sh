#!/bin/bash
# O2 产出验证
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server
echo '=== procs ==='
pgrep -fc batch_all_variants
echo '=== o2_57 files ==='
find $B/batch_o2_57 -name '*.json' 2>/dev/null | wc -l
for t in easy normal hard; do
  printf '%s: ' "$t"
  find $B/batch_o2_57 -name "$t*.json" 2>/dev/null | wc -l
done
echo '=== o2_8 files ==='
find $B/batch_o2_8 -name '*.json' 2>/dev/null | wc -l
for t in easy normal hard; do
  printf '%s: ' "$t"
  find $B/batch_o2_8 -name "$t*.json" 2>/dev/null | wc -l
done
echo '=== logs tail ==='
tail -3 /root/gen_o2_57.log 2>/dev/null
echo '---'
tail -3 /root/gen_o2_8.log 2>/dev/null
echo '=== o1 summary remaining ==='
printf 'o1_9: '; find $B/batch_o1_9 -name '*.json' 2>/dev/null | wc -l
echo CHECK_O2_DONE
