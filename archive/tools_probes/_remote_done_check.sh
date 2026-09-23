#!/bin/bash
# 服务器：完成确认
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server/batch_all
echo "=== 时间 ==="
date '+%F %T %Z'
echo "=== 报告文件（存在=该分片完成）==="
ls -la $B/all_report_shard_*.json 2>/dev/null || echo "(none yet)"
echo "=== 各分片 issues ==="
for i in 0 1; do
  f=$B/issues_shard_0$i.jsonl
  if [ -f "$f" ]; then
    echo "shard $i: 总行 $(wc -l < $f) | unit_done $(grep -c 'unit_done' "$f")"
  fi
done
echo "=== 产关数 ==="
find $B -name "*.json" ! -name "all_report*" ! -name "issues*" | wc -l
echo "=== 组合目录数 ==="
ls $B | grep -v "all_report" | grep -v "issues" | wc -l
echo "=== 进程数 ==="
pgrep -fc batch_all_variants || echo 0
echo "=== watchdog 日志尾 5 行 ==="
tail -5 /root/watchdog.log 2>/dev/null || echo "(no watchdog log)"
echo DONE_CHECK
