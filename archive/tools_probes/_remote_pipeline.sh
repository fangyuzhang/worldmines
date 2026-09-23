#!/bin/bash
# 服务器任务流水线 v2：按「空位」补位（始终保持 2 路并行，目标 ~95% CPU）
# 逻辑：每当运行中的生成任务 < 2 且队列还有任务 → 立即补一个；队列跑完 → 等最后的任务结束。
# 队列文件：/root/wm_queue.txt（每行一个任务的参数尾部；# 开头为注释）
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
QUEUE=/root/wm_queue.txt
PLOG=/root/pipeline.log

log() { echo "[pipeline $(date '+%m-%d %H:%M:%S')] $*" | tee -a "$PLOG"; }

mapfile -t ALL < <(grep -v '^#' "$QUEUE" 2>/dev/null | grep -v '^[[:space:]]*$')
log "pipeline v2 armed; queue size=${#ALL[@]}"

idx=0
while [ "$idx" -lt "${#ALL[@]}" ]; do
  running=$(pgrep -fc 'batch_all_variants' 2>/dev/null || echo 0)
  if [ "$running" -lt 2 ]; then
    log "START[slot $((running+1))]: ${ALL[$idx]}"
    setsid nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- ${ALL[$idx]} >> /root/pipeline_jobs.log 2>&1 < /dev/null &
    idx=$((idx + 1))
    sleep 25
  else
    sleep 60
  fi
done

while pgrep -f 'batch_all_variants' >/dev/null 2>&1; do sleep 60; done
log 'QUEUE ALL FINISHED'
