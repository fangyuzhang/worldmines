#!/bin/bash
# O1B 实测 + 全局进度
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server
echo "=== o1b_7 ==="
find $B/batch_o1b_7 -name '*.json' 2>/dev/null | wc -l
for t in easy normal hard; do
  printf "%s: " "$t"
  find $B/batch_o1b_7 -name "$t*.json" 2>/dev/null | wc -l
done
echo "=== o1b_8 ==="
find $B/batch_o1b_8 -name '*.json' 2>/dev/null | wc -l
for t in easy normal hard; do
  printf "%s: " "$t"
  find $B/batch_o1b_8 -name "$t*.json" 2>/dev/null | wc -l
done
echo "=== o2 progress (running) ==="
printf "o2_57: "; find $B/batch_o2_57 -name '*.json' | wc -l
printf "o2_8: "; find $B/batch_o2_8 -name '*.json' | wc -l
echo "=== load ==="
uptime
echo O1B_CHECK_DONE
