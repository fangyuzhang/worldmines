#!/bin/bash
# 服务器：看 shard 0 报告 + shard 1 当前单元
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server/batch_all
echo "=== all_report_shard_00.json ==="
cat $B/all_report_shard_00.json 2>/dev/null
echo ""
echo "=== shard_01 issues 最后 3 行 ==="
grep 'unit_done' $B/issues_shard_01.jsonl | tail -3
echo "=== shard_00 issues 最后 2 行 ==="
grep 'unit_done' $B/issues_shard_00.jsonl | tail -2
echo "=== 目录大小 ==="
du -sh $B 2>/dev/null
echo PEEK_DONE
