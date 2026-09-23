#!/bin/bash
# 重启流水线（v1 → v2）
export HOME=/root
pkill -f 'pipeline.sh' 2>/dev/null
sleep 2
setsid nohup bash /root/pipeline.sh > /root/pipeline_boot.log 2>&1 < /dev/null &
sleep 6
echo '=== pipeline proc ==='
pgrep -af 'pipeline.sh' || echo 'NOT RUNNING'
echo '=== boot log ==='
cat /root/pipeline_boot.log 2>/dev/null
echo '=== running batch jobs ==='
pgrep -fc 'batch_all_variants'
echo PIPELINE_V2_DONE
