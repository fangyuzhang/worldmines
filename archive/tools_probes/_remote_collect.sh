#!/bin/bash
# 服务器：全量产物打包含 issues/报告/关卡（收集回本地分析用）
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server/batch_all
cd /root
rm -f /root/wm_results.tar.gz
tar -czf /root/wm_results.tar.gz -C "$B" . 2>/dev/null
echo "=== 包大小 ==="
ls -la /root/wm_results.tar.gz
echo "=== 产关数 ==="
find "$B" -name "*.json" 2>/dev/null | grep -v report | wc -l
echo "=== 报告/事件文件 ==="
ls "$B" | grep -E "report|issues"
echo "=== issues 行数 ==="
for f in "$B"/issues_shard_*.jsonl; do
  [ -f "$f" ] && echo "$(basename $f): $(wc -l < "$f")"
done
echo COLLECT_DONE
