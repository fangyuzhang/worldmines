export HOME=/root
echo '=== gen_gap_A.log 尾部（o4 当前活动）==='
tail -6 /root/gen_gap_A.log 2>/dev/null | cut -c1-160
echo
echo '=== gen_gap_A.log 里 o4 相关的最近 unit/attempt 行 ==='
grep -E 'o4|unit|UNIT|attempt|停滞|stall|timeout' /root/gen_gap_A.log 2>/dev/null | tail -8 | cut -c1-160
echo
echo '=== batch_o4 issues.jsonl 最近事件（带时间戳）==='
B=/root/.local/share/godot/app_userdata/wm_server
f=$(ls -t $B/batch_o4/issues*.jsonl 2>/dev/null | head -1)
echo "issues 文件: $f ($(stat -c %s $f 2>/dev/null) bytes, 改于 $(stat -c %y $f 2>/dev/null | cut -c1-19))"
tail -3 "$f" 2>/dev/null | cut -c1-200
echo
echo '=== batch_o4 最新写入的关卡文件时间 ==='
ls -lt --time-style='+%m-%d %H:%M' $(find $B/batch_o4 -name '*.json' | grep -v report) 2>/dev/null | head -3 | awk '{print $6, $7, $8}'
echo '=== 当前时间 ==='
date '+%m-%d %H:%M'
echo '=== CPU 在干嘛（o4 进程线程状态抽样）==='
pid=$(pgrep -f 'Godot.*batch_all_variants' | head -1)
cat /proc/$pid/status 2>/dev/null | grep -E 'Threads|State'
top -b -n 1 -p $pid 2>/dev/null | tail -2
echo O4_DIAG_DONE
