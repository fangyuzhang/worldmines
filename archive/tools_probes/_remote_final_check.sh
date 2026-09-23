cd /root/minesweeper
echo '=== 服务器 mods 清单 ==='
ls demo/mods/
echo '=== 本轮新增 12 个 mod 齐备性 ==='
miss=0
for m in s1_jinxing s2_zhongxin s3_wuhuan s4_yangcong s5_hanglie s6_duou s7_fenliang z1_jingxiang z2_xianglin z3_sixiang z4_hangliesu z5_dengcha; do
  if [ -f "demo/mods/$m/entry.gd" ] && [ -f "demo/mods/$m/manifest.json" ]; then
    echo "  OK   $m"
  else
    echo "  MISS $m"
    miss=$((miss+1))
  fi
done
echo "缺失数: $miss"
echo '=== 链状态 ==='
ps -eo pid,etime,args | grep '[g]ap_chain.sh' | cut -c1-70
cat /root/gen_chain_main.log
echo '=== Godot 实进程（第一轮应 = 2）==='
ps -eo pid,etime,comm= | grep Godot | cut -c1-50
echo '=== 产物进度（关键批次）==='
B=/root/.local/share/godot/app_userdata/wm_server
for d in batch_o10 batch_o8 batch_o4 batch_o5x batch_o9 batch_s1 batch_s2; do
  if [ -d "$B/$d" ]; then
    n=$(find "$B/$d" -name '*.json' | grep -v report | wc -l)
    echo "  $d: $n 关"
  fi
done
echo '=== 旧守护残留（应为 0）==='
ps -eo pid,args | grep '[b]atch_all_variants' | grep -c 'while pgrep'
echo FINAL_CHECK_DONE
