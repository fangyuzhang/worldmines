export HOME=/root
echo '=== 所有含 batch_all_variants 的进程 ==='
ps -eo pid,etime,args | grep '[b]atch_all_variants' | cut -c1-150
echo
echo '=== 守护进程数（含 while pgrep 的 bash）==='
ps -eo pid,args | grep '[b]atch_all_variants' | grep -c 'while pgrep'
echo '=== Godot 实进程数 ==='
pgrep -fc 'Godot_v4.7.2.*batch_all_variants'
echo
echo '=== 各轮日志存在性 + 尾部 ==='
for f in /root/gen_gap_A.log /root/gen_gap_B.log /root/gen_gap_C.log /root/gen_gap_D.log /root/gen_gap_E.log /root/gen_gap_F.log /root/gen_gap_G.log /root/gen_gap_H.log /root/gen_gap_I.log /root/gen_gap_Z.log /root/gen_gap_S3.log /root/gen_gap_S5.log /root/gen_gap_S7.log; do
  if [ -f "$f" ]; then
    echo "--- $f ($(stat -c %s $f) bytes) ---"
    tail -1 "$f" | cut -c1-120
  else
    echo "--- $f : 不存在 ---"
  fi
done
echo
echo '=== 产物目录进度 ==='
B=/root/.local/share/godot/app_userdata/wm_server
for d in $(ls -d $B/batch_* 2>/dev/null); do
  n=$(find "$d" -name '*.json' 2>/dev/null | grep -v report | wc -l)
  echo "  $(basename $d): $n 关"
done
echo '=== load ==='
uptime
echo CHAIN_AUDIT_DONE
