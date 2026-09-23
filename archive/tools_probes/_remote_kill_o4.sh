export HOME=/root
echo '=== 杀挂死的 o4 Godot（1428550）==='
kill 1428550 2>/dev/null && echo '  已发 SIGTERM'
sleep 5
if ps -p 1428550 > /dev/null 2>&1; then
  echo '  仍存活，SIGKILL'
  kill -9 1428550
  sleep 2
fi
echo '=== 剩余 Godot（应为 0）==='
ps -eo comm= | grep -c '^Godot'
sleep 10
echo '=== 第一轮 wrapper（419911）应自然退出 ==='
ps -p 419911 > /dev/null 2>&1 && echo '  419911 仍在（随 lane A 序列）' || echo '  419911 已退出'
echo '=== 补产链应启动（等 320s 内）==='
for i in $(seq 1 16); do
  if [ -f /root/gen_chain_A.log ] || [ -f /root/gen_chain_B.log ]; then break; fi
  sleep 20
done
if [ -f /root/gen_chain_main.log ]; then tail -2 /root/gen_chain_main.log; fi
for f in /root/gen_chain_A.log /root/gen_chain_B.log; do
  if [ -f "$f" ]; then echo "--- $f ---"; grep -E '^--- \[' "$f" | tail -2; fi
done
echo '=== Godot 进程（lane 启动后应为 2）==='
ps -eo pid,etime,comm= | grep '^Godot' | cut -c1-45
echo KILL_DONE
