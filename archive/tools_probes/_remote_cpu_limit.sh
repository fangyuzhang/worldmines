#!/bin/bash
# 给 o10 限速 80%（留 5% 应急余量），o9 保持全速
export HOME=/root
if ! command -v cpulimit >/dev/null 2>&1; then
  echo '=== installing cpulimit ==='
  dnf install -y epel-release >/dev/null 2>&1
  dnf install -y cpulimit 2>&1 | tail -2
fi
command -v cpulimit && echo 'cpulimit available'
PID=$(pgrep -f 'batch_o10' | head -1)
echo "o10 pid=$PID"
if [ -n "$PID" ] && command -v cpulimit >/dev/null 2>&1; then
  pkill -f 'cpulimit' 2>/dev/null
  sleep 1
  nohup cpulimit -p "$PID" -l 80 -b >/root/cpulimit_o10.log 2>&1 &
  sleep 2
  echo '=== cpulimit running ==='
  pgrep -af cpulimit
else
  echo 'skip limiting (no cpulimit or no pid)'
fi
echo CPU_LIMIT_DONE
