export HOME=/root
for t in o4 o5x o8; do
  f=/root/.local/share/godot/app_userdata/wm_server/batch_$t/issues.jsonl
  echo "=== $t ==="
  if [ -f "$f" ]; then
    echo "总行数: $(wc -l < $f)"
    echo "事件分布:"
    grep -o '"t":"[a-z_]*"' "$f" | sort | uniq -c | sort -rn | head -12
    echo "最后 1 行 unit_done:"
    grep 'unit_done' "$f" | tail -1 | cut -c1-260
  else
    echo "no issues file"
  fi
done
echo WASTE_STATS_DONE2
