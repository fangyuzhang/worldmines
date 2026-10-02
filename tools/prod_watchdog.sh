#!/bin/bash
# prod_watchdog.sh —— 生产看门狗（2026-09-24 建；2026-09-27 **判据重构**）
#
# 【09-27 为什么必须重构 —— 三条判据被实测证伪】
#   当日现场：s7_normal 窗口日志已是「完成(1.0s)｜续跑满额跳过 5」（无活可干），
#   但那个 Godot 以 104% CPU 空转 **7h17m**，父窗口 shell 一直等它，整条计划被锁死 3 天。
#   抓现场（/proc/<pid>/）：**State: S (sleeping) / wchan=futex_wait_queue / 13 线程 / CPU 均值 8.4%**。
#   ⇒ ① 判据要求 CPU ≥ 80% **永远抓不到**这个主流故障类 —— 真凶是 **native 侧线程死锁
#      （futex 等待丢唤醒）**，进程**在等、不在算**，CPU 自然很低。这也是历史记录里
#      「6 个子进程同时挂死、CPU 近 0」的同一现象（低 CPU 不是"卡在 IO"，是死在 futex）。
#   ⇒ ② 命中后只发 **TERM** 无效：卡在 futex 的线程根本不处理信号（实测「TERM 无效 → KILL」）。
#      必须 TERM → 等 grace → **KILL** → 复核。
#   ⇒ ③ `[ -n "$last" ] || continue`（本轮零写入就不判）把「启动即挂死」也放过了 ——
#      而那类进程连 issues.jsonl 都没来得及写。
#
# 【死锁对"墙钟上限"的推论（写进结论，勿再依赖）】
#   既然主线程卡在 futex，`max_time_in_seconds` / `max_deterministic_time` 这类**求解器内部**
#   上限对它**完全无效**（死锁线程不会去看计时器）。累计预算（probe/core_budget_ms）治的是
#   「若干次有界 Solve 串起来」的累积浪费，**治不了死锁**。死锁只能靠**进程外 KILL** 兜住
#   → 本看门狗是唯一防线，必须常驻。
#
# 判据（重构后）：
#   ① 命令行含 batch_all_variants.gd / fill_window.gd（补产类进程）
#   ② **零产出时长 ≥ STALL_MIN 分钟**（主判据；本轮无任何进度文件时以进程寿命计）
#   ③ CPU 仅用于**分类取证**（≥80 = spinning 死循环；否则 = sleeping/futex 死锁），不参与杀/不杀
# 杀与不杀：
#   · 命中 KILL_TAGS（默认 thinfill|cmp_）：杀 —— 该族由 curated 计划驱动，自带重试且幂等续跑。
#   · 其它：只取证不杀（避免误伤跑了数天的长批次）。
#
# 用法（服务器）：nohup bash tools/prod_watchdog.sh > /dev/null 2>&1 &
#   STALL_MIN（**默认 15 分钟**，2026-10-01 C2 起；旧默认 120 只因当时只有单元级进度可见）
#   POLL_S（默认 300 秒）/ KILL_TAGS / EVID_DIR / KILL_GRACE_S（默认 20）
#   自监控：每轮写 $EVID_DIR/watchdog_heartbeat.txt；计划侧每轮开始检查其新鲜度（>900s 告警）
set -u
# 【2026-10-01 C2】STALL_MIN 默认 **120 → 15 分钟**。
# 为什么现在才敢下调：原判据只能看到**单元级**进度（issues*.jsonl 只在单元结束写），
# 一个单元合法可跑数十分钟 ⇒ 阈值不得不设 120。`batch_all_variants.gd` 现已**逐候选**写
# `<out>/heartbeat.txt`（覆盖写，含 combo/side/seed/耗时上限），本脚本把它纳入进度文件集 ⇒
# 「零产出」粒度从单元降到**单个候选**，15 分钟足以覆盖最慢的合法候选，
# 中招的计划锁死从 ≤2h 降到 ≤15min（6–8×）。
# 仍可用 `STALL_MIN=... nohup ...` 覆盖（旧值 120 仅作兼容参考）。
STALL_MIN="${STALL_MIN:-15}"
POLL_S="${POLL_S:-300}"
KILL_TAGS="${KILL_TAGS:-thinfill|cmp_}"
EVID_DIR="${EVID_DIR:-/root/hang_evidence}"
KILL_GRACE_S="${KILL_GRACE_S:-20}"
# KILL_TAGS 必须覆盖所有**有自动重试**的泳道：thinfill（单席位补产）+ cmp_（复合档计划，
# 目录名 user://cmp_*）。漏掉的后果：复合计划挂死时只取证不杀，而它的 wait_core 是
# 「全机 Godot 数 ≥ nproc 就等」⇒ 一个不死的进程把整条计划**永久**锁住（不只是丢一轮）。
BASE=/root/.local/share/godot/app_userdata/wm_server
mkdir -p "$EVID_DIR"
log() { echo "[$(date '+%F %H:%M:%S')] $*" >> "$EVID_DIR/watchdog.log"; }
log "看门狗启动（09-27 判据重构版）：STALL_MIN=${STALL_MIN}min POLL_S=${POLL_S}s KILL_TAGS=$KILL_TAGS GRACE=${KILL_GRACE_S}s"

while true; do
  # 【2026-10-01 C2 自监控】看门狗自己死了没人知道（"兜底组件失效"是 §12.2 列明的风险）。
  # 每轮落一个心跳文件；计划侧（thin_cells.py 生成的脚本体）在**每轮开始前**检查它的新鲜度，
  # 超过 900s 未更新就大声告警（POLL_S=300 时正常应 <600s）。
  echo "$(date '+%s') pid=$$ stall_min=$STALL_MIN" > "$EVID_DIR/watchdog_heartbeat.txt" 2>/dev/null || true
  sleep "$POLL_S"
  now=$(date '+%s')
  for p in $(pgrep -f 'Godot' 2>/dev/null); do
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
    echo "$cmd" | grep -qE 'batch_all_variants|fill_window' || continue
    out=$(echo "$cmd" | grep -oE 'user://[A-Za-z0-9_]+' | head -1)
    [ -n "$out" ] || continue
    dir="$BASE/${out#user://}"
    [ -d "$dir" ] || continue

    et=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')
    et=${et:-0}
    start=$(( now - et ))
    # 只统计**本进程启动之后**写入的进度文件（覆盖 .json、.jsonl 与 heartbeat.txt）：
    #   · 进度事件在 issues*.jsonl（单元级）
    #   · 【2026-10-01 C2】heartbeat.txt = batch_all_variants.gd 的**逐候选**心跳（覆盖写）
    #     ⇒ 有了它才能把 STALL_MIN 降到 15min（否则只能按单元粒度保守设 120min）
    last=$(find "$dir" \( -name '*.json' -o -name '*.jsonl' -o -name 'heartbeat.txt' \) -newermt "@$start" \
             -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
    if [ -n "$last" ]; then
      idle_min=$(( (now - last) / 60 ))
    else
      # 【09-27 修】本轮零写入 ⇒ 以**进程寿命**计 idle（原实现直接 continue，放过了"启动即挂死"）。
      idle_min=$(( et / 60 ))
    fi
    [ "$idle_min" -ge "$STALL_MIN" ] || continue

    # 分类取证（不参与判决）
    cpu=$(ps -p "$p" -o %cpu= 2>/dev/null | tr -d ' ' | cut -d. -f1)
    st=$(ps -o stat= -p "$p" 2>/dev/null | tr -d ' ')
    wchan=$(cat "/proc/$p/wchan" 2>/dev/null || echo '?')
    nthreads=$(grep -c . "/proc/$p/task/"*/stat 2>/dev/null || echo '?')
    kind="sleeping(疑 futex 死锁)"
    [ "${cpu:-0}" -ge 80 ] && kind="spinning(疑死循环)"

    ts=$(date '+%Y%m%d_%H%M%S')
    ev="$EVID_DIR/hang_${ts}_pid${p}.txt"
    {
      echo "=== 疑似挂死 $(date '+%F %H:%M:%S') ==="
      echo "PID=$p  CPU=${cpu:-?}%  零产出=${idle_min}min  进程寿命=${et}s  判定类别=$kind"
      echo "STAT=$st  wchan=$wchan  threads=$nthreads"
      echo "（判据：零产出 ≥ ${STALL_MIN}min 即命中，**不看 CPU** —— 09-27 现场实测"
      echo "  真凶是 futex 等待丢唤醒，State=S/CPU≈8%，旧版 CPU≥80% 判据永远抓不到它）"
      echo "--- 命令行 ---"; echo "$cmd"
      echo "--- 该轮 issues 末 3 行（卡在哪个 seed / 单元）---"
      tail -3 "$dir"/issues*.jsonl 2>/dev/null || echo "（无 issues 文件 —— 启动即挂死也属正常命中）"
      echo "--- 各尺寸产出计数 ---"
      for sub in "$dir"/*/*x*; do
        [ -d "$sub" ] && printf "  %-28s %s\n" "${sub#"$dir"/}" "$(find "$sub" -name '*.json' | wc -l)"
      done
      echo "--- 关联日志末 10 行 ---"
      tail -10 /root/gen_window_*.log /root/fill_*.log 2>/dev/null | tail -14
      echo "--- 内核态线程快照（futex 死锁的关键证据）---"
      for t in "/proc/$p/task/"*/; do
        tid=$(basename "$t")
        echo "  tid=$tid state=$(cut -d' ' -f3 "$t/stat" 2>/dev/null) wchan=$(cat "$t/wchan" 2>/dev/null)"
      done | head -16
      if command -v gdb >/dev/null 2>&1; then
        echo "--- gdb 栈（native/C# 混合；看是否停在 futex/pthread_cond_wait）---"
        timeout -k 5 60 gdb -batch -p "$p" -ex 'thread apply all bt 8' 2>&1 | head -50
      else
        echo "（无 gdb：只靠上面 wchan/内核态快照。装上可多一条直接证据：apt-get install -y gdb）"
      fi
    } > "$ev" 2>&1
    log "取证 → $ev（零产出 ${idle_min}min，类别=$kind，wchan=$wchan）"

    if echo "$out" | grep -qE "$KILL_TAGS"; then
      # TERM → 等 grace → KILL → 复核。不升级就是没杀（09-27 实测 TERM 对 futex 死锁无效）。
      kill "$p" 2>/dev/null || true
      gone=0
      for _i in $(seq 1 "$KILL_GRACE_S"); do
        sleep 1
        if ! kill -0 "$p" 2>/dev/null; then gone=1; break; fi
      done
      if [ "$gone" = "0" ]; then
        kill -9 "$p" 2>/dev/null || true
        sleep 2
        if kill -0 "$p" 2>/dev/null; then
          log "!! PID $p KILL(9) 后仍存活（可能处于不可中断状态）—— 需人工介入"
        else
          log "已杀 PID $p（族=$out；TERM 无效 → KILL(9) 生效，计划重试会自动续跑）"
        fi
      else
        log "已杀 PID $p（族=$out；TERM 生效）"
      fi
    else
      log "只取证不杀 PID $p（族=$out 无自动重试，交人工）"
    fi
  done
done
