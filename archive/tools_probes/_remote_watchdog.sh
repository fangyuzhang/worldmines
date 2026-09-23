#!/bin/bash
# 服务器：生成守护 v3（每 10 分钟状态摘要 + 分片异常重启续跑 + 停滞告警）
# 完成判定：all_report_shard_0X.json 存在（脚本末尾写报告 = 完成标记）
# 停滞告警：issues 行数连续 3 轮（30 分钟）不变 → WARN（不自动重启——
# 重线索单元可达 1.5h+，误杀代价大于等待；连续 WARN 需人工决策）
export HOME=/root
export GODOT_SILENCE_ROOT_WARNING=1
GD=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
B=/root/.local/share/godot/app_userdata/wm_server/batch_all
cd /root/minesweeper

while true; do
  sleep 600
  ts=$(date '+%F %T')
  done_all=1
  status=""
  for i in 0 1; do
    if [ ! -f "$B/all_report_shard_0$i.json" ]; then
      done_all=0
      pid=$(pgrep -f "user://batch_all 10 40 0 $i 2" | head -1)
      if [ -z "$pid" ]; then
        echo "[watchdog $ts] shard $i 异常退出，重启续跑" >> /root/watchdog.log
        nohup "$GD" --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_all 10 40 0 "$i" 2 >> "/root/gen_shard_$i.log" 2>&1 &
        status="$status s$i=restarted"
        echo 0 > /root/.wd_stall_$i
      else
        lines=$(wc -l < "$B/issues_shard_0$i.jsonl" 2>/dev/null || echo 0)
        status="$status s$i=run(pid=$pid,lines=$lines)"
        # 停滞检测：与上一轮行数相同 → stall+1；连续 3 轮 → WARN
        prev=$(cat /root/.wd_lines_$i 2>/dev/null || echo -1)
        if [ "$lines" = "$prev" ]; then
          stall=$(( $(cat /root/.wd_stall_$i 2>/dev/null || echo 0) + 1 ))
        else
          stall=0
        fi
        echo "$lines" > /root/.wd_lines_$i
        echo "$stall" > /root/.wd_stall_$i
        if [ "$stall" -ge 3 ] && [ $(( stall % 3 )) -eq 0 ]; then
          echo "[watchdog $ts] WARN: shard $i issues 行数连续 $stall 轮不变（$lines 行）——疑似停滞，请人工确认" >> /root/watchdog.log
        fi
      fi
    else
      status="$status s$i=done"
    fi
  done
  cnt=$(find "$B" -name "*.json" 2>/dev/null | grep -v report | wc -l)
  echo "[watchdog $ts]$status levels=$cnt" >> /root/watchdog.log
  if [ "$done_all" = "1" ]; then
    echo "[watchdog $ts] 全部分片完成，watchdog 退出" >> /root/watchdog.log
    break
  fi
done
