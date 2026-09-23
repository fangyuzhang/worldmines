#!/bin/bash
# 服务器：精确状态（时间 / 各分片单元数 / 当前最后单元 / 最新关卡 mtime / 进程）
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server/batch_all
echo "=== 现在时间 ==="
date '+%F %T %Z'
echo "=== 各分片 ==="
for i in 0 1; do
  f=$B/issues_shard_0$i.jsonl
  if [ -f "$f" ]; then
    echo "shard $i: 总行 $(wc -l < $f) | unit_done $(grep -c 'unit_done' "$f")"
    echo "  最后 2 条:"
    grep 'unit_done' "$f" | tail -2
  else
    echo "shard $i: 无 issues 文件"
  fi
done
echo "=== 最新 5 个关卡文件（mtime）==="
find $B -name "*.json" ! -name "all_report*" -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort | tail -5
echo "=== 各分片去重 combo 数 ==="
for i in 0 1; do
  f=$B/issues_shard_0$i.jsonl
  [ -f "$f" ] && echo "shard $i unique combos: $(grep 'unit_done' "$f" | grep -o '"combo":"[^"]*"' | sort -u | wc -l)"
done
echo "=== 进程数 ==="
pgrep -fc batch_all_variants
echo STATUS2_DONE
