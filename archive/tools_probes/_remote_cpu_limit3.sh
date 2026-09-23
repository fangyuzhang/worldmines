#!/bin/bash
# cpulimit 诊断 + 正确用法
export HOME=/root
echo '=== version ==='
cpulimit --version 2>&1 | head -2
echo '=== usage head ==='
cpulimit --help 2>&1 | head -12
echo '=== try: -l 80 -p PID (no -b) ==='
PID=$(pgrep -f 'batch_o10' | head -1)
echo "pid=$PID"
pkill -f cpulimit 2>/dev/null
sleep 1
if [ -n "$PID" ]; then
  setsid nohup cpulimit -l 80 -p "$PID" >/root/cpulimit_o10.log 2>&1 < /dev/null &
  sleep 3
  echo '=== after ==='
  pgrep -af cpulimit || echo 'still none'
  tail -3 /root/cpulimit_o10.log
fi
echo DIAG3_DONE
