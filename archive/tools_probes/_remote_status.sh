#!/bin/bash
# 综合状态查询（生成进度 / 守护 / systemd 服务 / 完成报告 / issues 心跳）
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server/batch_all
echo "=== 时间 ==="
date '+%F %T %Z'
echo "=== 生成进程数 ==="
pgrep -fc batch_all_variants || echo 0
echo "=== watchdog 进程 ==="
pgrep -af "watchdog.sh" | head -3 || echo "(none)"
echo "=== systemd 服务 wm-gen-watchdog ==="
systemctl is-active wm-gen-watchdog 2>/dev/null || echo "(no-service)"
systemctl is-enabled wm-gen-watchdog 2>/dev/null || echo "(not-enabled)"
echo "=== 产关数（不含报告）==="
find $B -name "*.json" 2>/dev/null | grep -v "all_report" | grep -v "issues" | wc -l
echo "=== 完成报告 ==="
ls -la $B/all_report_shard_*.json 2>/dev/null || echo "(none yet)"
echo "=== issues 行数 ==="
wc -l $B/issues_shard_0*.jsonl 2>/dev/null || echo "(no issues)"
echo "=== 最新 issues 心跳（unit_done 尾 4 行）==="
for f in $B/issues_shard_0*.jsonl; do
  [ -f "$f" ] || continue
  grep unit_done "$f" | tail -2
done
echo "=== watchdog 日志尾 8 行 ==="
tail -8 /root/watchdog.log 2>/dev/null || echo "(no watchdog log)"
echo "=== 分片日志尾 2 行 ==="
tail -2 /root/gen_shard_0.log 2>/dev/null; tail -2 /root/gen_shard_1.log 2>/dev/null
echo STATUS_DONE
