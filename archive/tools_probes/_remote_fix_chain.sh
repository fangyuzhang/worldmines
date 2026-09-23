export HOME=/root
cd /root/minesweeper

echo '=== 诊断：当前进程名（comm）中 Godot 相关 ==='
ps -eo comm= | grep -i godot | sort -u
echo '=== 旧守护（含 while pgrep 的 bash）PID 列表 ==='
ps -eo pid,args | grep '[b]atch_all_variants' | grep 'while pgrep' | awk '{print $1}'

echo '=== 杀掉旧守护（只杀命令行同时含 batch_all_variants 与 while pgrep 的 bash）==='
for pid in $(ps -eo pid,args | grep '[b]atch_all_variants' | grep 'while pgrep' | awk '{print $1}'); do
  kill "$pid" 2>/dev/null && echo "  killed $pid"
done
sleep 2
echo '剩余旧守护数:'
ps -eo pid,args | grep '[b]atch_all_variants' | grep -c 'while pgrep'
echo '第一轮 Godot 是否仍在跑（应为 2）:'
ps -eo comm= | grep -c '^Godot'

cat > /root/gap_chain.sh <<'CHAIN'
#!/bin/bash
# 补产链（合并版，2026-09-16 部署）
#
# 为什么重写：原先 11 个「各自轮询」的守护有**死锁缺陷**——它们用
#     pgrep -f 'batch_all_variants'
# 判断前序是否结束，而**每个守护自身的 bash -c 命令行里就含这个字符串**
# （既在 pgrep 模式内、也在其 Godot 命令内）→ pgrep 永远非空 → 第一轮结束后
# 所有守护永久等待，整条链静默停摆。
# 现改为：① 用**进程名**（comm）判断 Godot 是否在跑（bash 守护名不含 Godot）；
#        ② 全链只有**一个等待点**，之后开两条并行 lane（2 核各一路）。
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
BGD="res://tools/batch_all_variants.gd"

godot_running() { ps -eo comm= | grep -q '^Godot'; }

run() {
  local tag="$1"; shift
  echo "--- [$tag] start $(date '+%F %H:%M:%S') ---"
  "$G" --headless --path . -s "$BGD" -- "$@"
  echo "--- [$tag] done  $(date '+%F %H:%M:%S') exit=$? ---"
}

# 路 A：o1 → S1 → S4 → Z4 → Z1 → S3 → S5
lane_a() {
  run o1 user://batch_o1_merged 10 1200 -1 1 1 410 0 o1@5-9 o1_duichuan 100 3000 tiered 30
  run s1 user://batch_s1 10 1200 -1 1 1 0 0 classic+s1@5-9 s1_jinxing 100 3000 tiered 30
  run s4 user://batch_s4 10 1200 -1 1 1 0 0 classic+s4@5-9 s4_yangcong 100 3000 tiered 30
  run z4 user://batch_z4 10 1200 -1 1 1 0 0 classic+z4@5-9 z4_hangliesu 100 3500 tiered 30
  run z1 user://batch_z1 10 1200 -1 1 1 0 0 classic+z1@5-9 z1_jingxiang 100 3500 tiered 30
  run s3 user://batch_s3 10 2000 -1 1 1 0 0 classic+s3@5-9 s3_wuhuan 100 6000 tiered 30
  run s5 user://batch_s5 10 1200 -1 1 1 0 0 classic+s5@5-9 s5_hanglie 100 3500 tiered 30
  echo "LANE_A_DONE $(date '+%F %H:%M:%S')"
}

# 路 B：o2 → o3 → S2 → S6 → Z2 → Z3 → Z5 → S7
lane_b() {
  run o2 user://batch_o2_merged 10 1200 -1 1 1 410 0 o2@5-9 o2_linxu 100 3000 tiered 30
  run o3 user://batch_o3_merged 10 1200 -1 1 1 410 0 o3@5-9 o3_fendang 100 3000 tiered 30
  run s2 user://batch_s2 10 1200 -1 1 1 0 0 classic+s2@5-9 s2_zhongxin 100 3000 tiered 30
  run s6 user://batch_s6 10 1500 -1 1 1 0 0 classic+s6@5-9 s6_duou 100 4000 tiered 30
  run z2 user://batch_z2 10 1500 -1 1 1 0 0 classic+z2@5-9 z2_xianglin 100 4000 tiered 30
  run z3 user://batch_z3 10 1500 -1 1 1 0 0 classic+z3@5-9 z3_sixiang 100 3500 tiered 30
  run z5 user://batch_z5 10 1500 -1 1 1 0 0 classic+z5@5-9 z5_dengcha 100 3500 tiered 30
  run s7 user://batch_s7 10 2500 -1 1 1 0 0 classic+s7@5-9 s7_fenliang 100 6000 tiered 30
  echo "LANE_B_DONE $(date '+%F %H:%M:%S')"
}

echo "=== 补产链启动，等待第一轮（A/B 路）结束 $(date '+%F %H:%M:%S') ==="
while godot_running; do sleep 300; done
echo "=== 第一轮已结束，开两条 lane $(date '+%F %H:%M:%S') ==="
lane_a > /root/gen_chain_A.log 2>&1 &
lane_b > /root/gen_chain_B.log 2>&1 &
wait
echo "CHAIN_ALL_DONE $(date '+%F %H:%M:%S')"
CHAIN
chmod +x /root/gap_chain.sh

rm -f /root/gen_chain_main.log
setsid nohup /root/gap_chain.sh > /root/gen_chain_main.log 2>&1 &
sleep 4

echo '=== 修复后核验 ==='
echo '新链脚本进程:'
ps -eo pid,etime,args | grep '[g]ap_chain.sh' | cut -c1-90
echo 'Godot 实进程（第一轮应仍为 2）:'
ps -eo pid,etime,comm= | grep 'Godot' | cut -c1-60
echo '链条日志:'
cat /root/gen_chain_main.log
echo FIX_CHAIN_DONE
