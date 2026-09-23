#!/bin/bash
# cpulimit 重建（setsid 防 TAT 会话清理）
export HOME=/root
echo '=== cpulimit now ==='
pgrep -af cpulimit || echo none
echo '=== old log ==='
cat /root/cpulimit_o10.log 2>/dev/null | tail -3
PID=$(pgrep -f 'batch_o10' | head -1)
echo "o10 pid=$PID"
if [ -n "$PID" ]; then
  pkill -f cpulimit 2>/dev/null
  sleep 1
  setsid nohup cpulimit -p "$PID" -l 80 -b >/root/cpulimit_o10.log 2>&1 < /dev/null &
  sleep 3
  echo '=== after start ==='
  pgrep -af cpulimit || echo 'STILL NONE'
  echo '=== log ==='
  cat /root/cpulimit_o10.log 2>/dev/null | tail -3
fi
echo RELIMIT_DONE
