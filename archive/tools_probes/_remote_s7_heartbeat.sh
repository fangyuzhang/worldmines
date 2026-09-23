#!/bin/bash
# s7 批次心跳检查：unit_done 事件兼作心跳（HANDOFF 口径），看它是否仍在产出
B=/root/.local/share/godot/app_userdata/wm_server
D=$B/batch_s7
echo "=== batch_s7 规模与最近写入 ==="
find "$D" -name '*.json' -not -name '*report*' | wc -l
ls -lt "$D" | head -5
echo "=== issues.jsonl 最近的 unit_done 行 ==="
if [ -f "$D/issues.jsonl" ]; then
  ls -la "$D/issues.jsonl"
  grep unit_done "$D/issues.jsonl" | tail -3
  echo "unit_done 总行数: $(grep -c unit_done "$D/issues.jsonl")"
else
  echo "（无 issues.jsonl）"
  ls "$D" | head -10
fi
echo "=== 各尺寸目录关卡数 ==="
for s in 5x5 6x6 7x7 8x8 9x9; do
  [ -d "$D/x_s7/$s" ] && printf "  %s: %s\n" "$s" "$(find "$D/x_s7/$s" -name '*.json' | wc -l)"
done
echo "=== 进程与当前时间 ==="
date '+%F %H:%M:%S'
ps -eo pid,etime,pcpu,comm | grep -i godot | head -3
echo S7_HB_DONE
