export HOME=/root
echo '=== load / Godot 进程 ==='
uptime
ps -eo pid,etime,args | grep '[g]ap_chain.sh\|[b]atch_all_variants' | cut -c1-110
ps -eo pid,etime,comm= | grep '^Godot'
echo
echo '=== 链日志尾部 ==='
tail -2 /root/gen_chain_main.log 2>/dev/null
for f in /root/gen_chain_A.log /root/gen_chain_B.log; do
  if [ -f "$f" ]; then
    echo "--- $f 尾部 ---"
    grep -E '^--- \[' "$f" | tail -4
  else
    echo "--- $f 不存在（lane 未启动）---"
  fi
done
echo
echo '=== 各 batch 目录关数（只列今晨后可能变化的）==='
B=/root/.local/share/godot/app_userdata/wm_server
for d in $(ls -d $B/batch_* 2>/dev/null | sort); do
  n=$(find "$d" -name '*.json' 2>/dev/null | grep -v report | wc -l)
  echo "  $(basename $d): $n"
done
echo '=== 各 batch report.ok（判断完成度）==='
for d in $(ls -d $B/batch_* 2>/dev/null | sort); do
  r="$d/all_report.json"
  if [ -f "$r" ]; then
    s=$(python3 -c "import json;d=json.load(open('$r'));st=d.get('stats',{});print('ok=%s fail=%s'%(st.get('ok'),st.get('fail')))" 2>/dev/null)
    echo "  $(basename $d): $s"
  else
    echo "  $(basename $d): 无report（在跑或老批）"
  fi
done
echo STATUS_DONE
