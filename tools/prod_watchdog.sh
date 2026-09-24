#!/bin/bash
# prod_watchdog.sh —— 生产看门狗（2026-09-24）：把「挂死」从 14.5h 的静默损失变成**有界且有证据**的事件。
#
# 为什么必须进程外（根因分析）：
#   · 工具的 timeout 语义是「候选之间」判定：`_timeout_for(side)=max(30s, side²×coef)`，
#     9×9 + coef 3000 → 243s/候选；而 09-17 的挂死 ≥14.5h = 21× 该上限 ⇒ 单次求解未被截断。
#   · GDScript 是单线程的：C# CP-SAT 在一次阻塞求解里，GDScript 侧**无法**打断它。
#   ⇒ 只有外部监控能兜住：零产出 + CPU 满载 超阈值 → 取证（必要时杀）。
#
# 判据（三重，避免误杀慢但正常的单元）：
#   ① 命令行含 batch_all_variants.gd / fill_window.gd（补产类进程）
#   ② CPU ≥ 80%（不是等 IO/卡死休眠）
#   ③ 输出目录里最新 json 的 mtime 已过 STALL_MIN 分钟（真正零产出）
#
# 杀与不杀：
#   · 命中 KILL_TAGS（默认 thinfill）：**杀** —— 该族由 curated 计划驱动，自带 3 次重试，会自动续跑（幂等）。
#   · 其它（如 gap_chain 的长轮）：**只取证不杀** —— 交人工判断（避免误伤跑了 4 天的批次）。
#
# 取证内容（写到 $EVID_DIR/hang_<时间>_pid<PID>.txt）：
#   命令行 / 零产出时长 / 该尺寸产出计数 / **issues*.jsonl 末 3 行（= 卡在哪个 seed/单元）** /
#   关联日志末 10 行 / 有 gdb 时附 `thread apply all bt`（判「卡在求解器」还是卡在别处）。
#
# 用法（服务器）：nohup bash tools/prod_watchdog.sh > /dev/null 2>&1 &
#   环境变量：STALL_MIN（默认 120 分钟）/ POLL_S（默认 300 秒）/ KILL_TAGS（默认 thinfill）/ EVID_DIR
set -u
STALL_MIN="${STALL_MIN:-120}"
POLL_S="${POLL_S:-300}"
KILL_TAGS="${KILL_TAGS:-thinfill}"
EVID_DIR="${EVID_DIR:-/root/hang_evidence}"
BASE=/root/.local/share/godot/app_userdata/wm_server
mkdir -p "$EVID_DIR"
log() { echo "[$(date '+%F %H:%M:%S')] $*" >> "$EVID_DIR/watchdog.log"; }
log "看门狗启动：STALL_MIN=${STALL_MIN}min POLL_S=${POLL_S}s KILL_TAGS=$KILL_TAGS"

while true; do
  sleep "$POLL_S"
  now=$(date '+%s')
  for p in $(pgrep -f 'Godot' 2>/dev/null); do
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
    echo "$cmd" | grep -qE 'batch_all_variants|fill_window' || continue
    out=$(echo "$cmd" | grep -oE 'user://[A-Za-z0-9_]+' | head -1)
    [ -n "$out" ] || continue
    dir="$BASE/${out#user://}"
    [ -d "$dir" ] || continue
    cpu=$(ps -p "$p" -o %cpu= 2>/dev/null | tr -d ' ' | cut -d. -f1)
    last=$(find "$dir" -name '*.json' -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
    [ -n "$last" ] || continue
    idle_min=$(( (now - last) / 60 ))
    [ "${cpu:-0}" -ge 80 ] && [ "$idle_min" -ge "$STALL_MIN" ] || continue

    ts=$(date '+%Y%m%d_%H%M%S')
    ev="$EVID_DIR/hang_${ts}_pid${p}.txt"
    {
      echo "=== 疑似挂死 $(date '+%F %H:%M:%S') ==="
      echo "PID=$p  CPU=${cpu}%  零产出=${idle_min} 分钟  输出=$out"
      echo "--- 命令行 ---"; echo "$cmd"
      echo "--- 该轮 issues 末 3 行（关键：卡在哪个 seed / 单元）---"
      tail -3 "$dir"/issues*.jsonl 2>/dev/null || echo "（无 issues 文件）"
      echo "--- 各尺寸产出计数 ---"
      for sub in "$dir"/*/*x*; do
        [ -d "$sub" ] && printf "  %-28s %s\n" "${sub#"$dir"/}" "$(find "$sub" -name '*.json' | wc -l)"
      done
      echo "--- 关联日志末 10 行 ---"
      tail -10 /root/gen_window_*.log /root/fill_*.log 2>/dev/null | tail -14
      if command -v gdb >/dev/null 2>&1; then
        echo "--- gdb 栈（native/C# 混合；判「卡在求解器」用）---"
        timeout 60 gdb -batch -p "$p" -ex 'thread apply all bt 12' 2>&1 | head -60
      else
        echo "（无 gdb：跳过栈采样。装上可多一条「卡在哪」的直接证据：apt-get install -y gdb）"
      fi
    } > "$ev" 2>&1
    log "取证 → $ev（零产出 ${idle_min}min）"
    if echo "$out" | grep -qE "$KILL_TAGS"; then
      if kill "$p" 2>/dev/null; then
        log "已杀 PID $p（族=$out 命中 KILL_TAGS，计划自带重试会自动续跑）"
      fi
    else
      log "只取证不杀 PID $p（族=$out 无自动重试，交人工）"
    fi
  done
done
