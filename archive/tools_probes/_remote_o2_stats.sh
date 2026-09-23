#!/bin/bash
# O2 废品结构统计（issues 事件 + unit_done 心跳）
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server
for d in batch_o2_57 batch_o2_8; do
  echo "=== $d ==="
  if [ -f $B/$d/issues.jsonl ]; then
    echo "lines: $(wc -l < $B/$d/issues.jsonl)"
    grep -o '"t":"[a-z_]*"' $B/$d/issues.jsonl | sort | uniq -c | head -10
    echo "--- last unit_done ---"
    grep unit_done $B/$d/issues.jsonl | tail -1 | cut -c1-320
  else
    echo "(no issues yet)"
  fi
  echo "--- files ---"
  find $B/$d -name '*.json' 2>/dev/null | wc -l
  for t in easy normal hard; do
    printf '%s: ' "$t"
    find $B/$d -name "$t*.json" 2>/dev/null | wc -l
  done
done
echo O2_STATS_DONE
