#!/bin/bash
# 服务器 CPU 负载现状深查
export HOME=/root
echo '=== cpu cores ==='
nproc
echo '=== load average ==='
uptime
echo '=== top procs by cpu ==='
ps -eo pid,pcpu,pmem,etime,cmd --sort=-pcpu | head -8
echo '=== o9 progress ==='
B=/root/.local/share/godot/app_userdata/wm_server/batch_o9
echo "o9 json=$(find $B -name '*.json' 2>/dev/null | wc -l)"
echo '=== mem ==='
free -m | head -3
echo '=== vmstat 3s ==='
vmstat 1 4 2>/dev/null || echo 'no vmstat'
echo CPU_CHECK_DONE
