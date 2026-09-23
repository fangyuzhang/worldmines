export HOME=/root
echo '=== load / 进程 ==='
uptime
ps -eo pid,etime,args | grep '[g]ap_chain.sh\|[b]atch_all_variants' | cut -c1-100
echo 'Godot 实进程数:'
ps -eo comm= | grep -c '^Godot'
echo
echo '=== 链日志（主/A/B）==='
for f in /root/gen_chain_main.log /root/gen_chain_A.log /root/gen_chain_B.log; do
  if [ -f "$f" ]; then
    echo "--- $f ($(stat -c %s $f)B) 尾部: ---"
    tail -3 "$f" | cut -c1-140
  else
    echo "--- $f 不存在 ---"
  fi
done
echo
echo '=== 全部产物目录关数 ==='
B=/root/.local/share/godot/app_userdata/wm_server
for d in $(ls -d $B/batch_* 2>/dev/null | sort); do
  n=$(find "$d" -name '*.json' 2>/dev/null | grep -v report | wc -l)
  echo "  $(basename $d): $n 关"
done
echo '=== issues 汇总（各 batch 的 all_report.json stats）==='
for d in $(ls -d $B/batch_* 2>/dev/null | sort); do
  r="$d/all_report.json"
  if [ -f "$r" ]; then
    s=$(python3 -c "import json;d=json.load(open('$r'));st=d.get('stats',{});print('ok=%s fail=%s units=%s'% (st.get('ok'),st.get('fail'),st.get('units')))" 2>/dev/null)
    echo "  $(basename $d): $s"
  fi
done
echo '=== 链是否已收尾 ==='
grep -l 'CHAIN_ALL_DONE\|LANE_._DONE' /root/gen_chain_*.log 2>/dev/null || echo '（未见完成标记）'
echo STATUS_DONE
