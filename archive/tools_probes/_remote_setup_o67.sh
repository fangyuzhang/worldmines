#!/bin/bash
# 服务器侧：① 归档旧变体产物 batch_all（83 个旧组合 / 3597 关）② 安装并在主链结束后自动补批 o6/o7
set -u
B=/root/.local/share/godot/app_userdata/wm_server

echo "=== ① 归档旧变体产物（batch_all → /root/archive/）==="
mkdir -p /root/archive
if [ -d "$B/batch_all" ]; then
  mv "$B/batch_all" "/root/archive/batch_all_legacy_$(date +%Y%m%d)" && echo "已归档: /root/archive/batch_all_legacy_$(date +%Y%m%d)"
else
  echo "batch_all 不存在（可能已归档）"
fi
ls -d /root/archive/* 2>/dev/null | tail -3

echo
echo "=== ② 写补批脚本 /root/gap_chain2.sh ==="
cat > /root/gap_chain2.sh <<'EOF'
#!/bin/bash
# gap_chain2.sh —— 主链（gap_chain.sh，15 批）跑完后自动补批：
#   o6（热度）/ o7（奇显）—— 主链漏排的两个**观测轴**算子（总表 T2 观测各 20 集 / 2000 关）
# 触发判据：主链日志出现 CHAIN_ALL_DONE **且** 无 Godot 进程（防与主链抢核）
# 产物目录：x_o6 / x_o7（导入工具已支持该形态：mode 按关卡 JSON 推导，2026-09-19 修复）
CD=/root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
BGD="res://tools/batch_all_variants.gd"
LOG=/root/gen_chain2.log
cd "$CD" || exit 1

godot_running() { ps -eo comm= | grep -q '^Godot'; }

run() {
  local name="$1"; shift
  echo "[$(date '+%F %H:%M:%S')] 开始 $name" >> "$LOG"
  "$G" --headless --path . -s "$BGD" -- "$@" >> "$LOG" 2>&1
  echo "[$(date '+%F %H:%M:%S')] 结束 $name" >> "$LOG"
}

lane_a() {
  run o6 user://batch_o6 10 1500 -1 1 1 0 0 o6@5-9 o6_redu 100 3000 tiered 30
  echo "LANE_A_DONE $(date '+%F %H:%M:%S')" >> "$LOG"
}
lane_b() {
  run o7 user://batch_o7 10 1500 -1 1 1 0 0 o7@5-9 o7_qixian 100 3000 tiered 30
  echo "LANE_B_DONE $(date '+%F %H:%M:%S')" >> "$LOG"
}

echo "=== gap_chain2 启动，等待主链结束 $(date '+%F %H:%M:%S') ===" >> "$LOG"
while true; do
  if grep -q CHAIN_ALL_DONE /root/gen_chain_main.log 2>/dev/null && ! godot_running; then
    break
  fi
  sleep 300
done
echo "=== 主链已结束，o6/o7 双 lane 开跑 $(date '+%F %H:%M:%S') ===" >> "$LOG"
lane_a & lane_b & wait
echo "CHAIN2_ALL_DONE $(date '+%F %H:%M:%S')" >> "$LOG"
EOF
chmod +x /root/gap_chain2.sh
echo "已写: $(wc -l < /root/gap_chain2.sh) 行"

echo
echo "=== ③ 启动补批守护（setsid，脱离本会话）==="
if pgrep -f 'gap_chain2\.sh' >/dev/null; then
  echo "已在运行，不重复启动"
else
  setsid nohup bash /root/gap_chain2.sh >/dev/null 2>&1 &
  sleep 2
  pgrep -af 'gap_chain2\.sh' | head -2
fi
echo
echo "=== ④ 状态确认 ==="
tail -3 /root/gen_chain2.log 2>/dev/null
ps -eo pid,etime,comm= | grep Godot | cut -c1-46
