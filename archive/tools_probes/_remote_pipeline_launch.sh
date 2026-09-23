#!/bin/bash
# 启动任务流水线（setsid 脱离 TAT 会话）
export HOME=/root
cd /root
setsid nohup bash /root/pipeline.sh > /root/pipeline_boot.log 2>&1 < /dev/null &
sleep 6
echo '=== pipeline proc ==='
pgrep -af 'pipeline.sh' || echo 'NOT RUNNING'
echo '=== boot log ==='
cat /root/pipeline_boot.log 2>/dev/null
echo '=== queue ==='
cat /root/wm_queue.txt
echo PIPELINE_LAUNCH_DONE
