#!/usr/bin/env bash
# fill_level_lib.sh —— 服务器侧「口径自检 + 量产」一键脚本（Linux / macOS）。
#
# 与 fill_level_lib.ps1 的分工（重要）：
#   · 本脚本只做 **A 阶段（量产）**：产物落在 user://batch_all；
#   · 干跑（--dry-run）与导入（要写 res://levels_lib/ 并提交仓库）在**开发机**用 .ps1 做
#     —— 仓库变更集中在一处发生，服务器只负责「出关卡」。
#
# 用法：
#   ./tools/fill_level_lib.sh           # 自检 → 2 分片量产（每档 100 关）
#   ./tools/fill_level_lib.sh -t 20     # 每档 20 关（22 席全覆盖优先；2 核约 3~4.5h）
#   ./tools/fill_level_lib.sh -s 4      # 分片数（**不要超过核数**，否则互相抢 CPU 反而更慢）
#   ./tools/fill_level_lib.sh -c        # 只做口径自检不跑量产（开跑前应至少看一次）
#
# 若提示 Permission denied：用 `bash tools/fill_level_lib.sh ...` 调用即可
#（Windows 上的 git 不记录可执行位，克隆到 Linux 后本文件可能没有 +x）。
#
# ⚠️ 远程跑必须挂住会话：ssh 直连时用 nohup 或 screen/tmux，否则断线即被杀（几小时的活白跑）：
#   nohup bash tools/fill_level_lib.sh -t 20 > run.log 2>&1 &
#   # 或：tmux new -s fill 'bash tools/fill_level_lib.sh -t 20'
#
# 环境变量：GODOT=<godot 可执行路径>（缺省从 PATH 找 godot）；
#           SHARDS / PER_TIER / SEED_MAX / TIMEOUT_COEF / STALL_MAX / OUT_DIR 亦可环境变量覆盖。
#           **SEED_MAX=0（默认）= 自动 = max(40, PER_TIER×10)**——每单元种子上限；
#           它才是「每集最多能有多少关」的硬上限（每 seed 至多 1 关），PerTier 只在上限内生效。
#           服务器链实测：每档 100 关用 seed 上限 1200 上下。要压预算再显式给 SEED_MAX=200 之类。
#
# 为什么必须先口径自检：量产唯一会导致「全批报废」的错误是在**旧口径代码**上跑 ——
# 产物组合目录名与选关页 MODES[].id 对不上，关卡进库了也永远点不到，且全程不报错。
# 自检不通过本脚本直接退出（先 git pull 到含自检的版本）。
#
# 两阶段建议（断点续跑天然支持）：先 -t 20 拿 22 席全覆盖，再 -t 50/100 增量补满
#（满额单元自动跳过，已工作的部分不浪费）。
set -euo pipefail

SHARDS="${SHARDS:-2}"
PER_TIER="${PER_TIER:-100}"
SEED_MAX="${SEED_MAX:-0}"
TIMEOUT_COEF="${TIMEOUT_COEF:-6000}"
STALL_MAX="${STALL_MAX:-60}"
OUT_DIR="${OUT_DIR:-user://batch_all}"
CHECK_ONLY=0

while getopts "s:t:ch" opt; do
  case "$opt" in
    s) SHARDS="$OPTARG" ;;
    t) PER_TIER="$OPTARG" ;;
    c) CHECK_ONLY=1 ;;
    h|*) sed -n '2,26p' "$0"; exit 0 ;;
  esac
done

GODOT="${GODOT:-godot}"
if ! command -v "$GODOT" >/dev/null 2>&1; then
  echo "找不到 Godot：$GODOT（用 GODOT=/path/to/godot 指定，或确保它在 PATH 里）" >&2
  exit 1
fi
[ -f project.godot ] || { echo "请在项目根目录（含 project.godot）运行本脚本" >&2; exit 1; }

CORES="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
# SeedMax=0（默认）→ 自动 = max(40, PER_TIER×10)。
# 为什么：量产工具里 seed_max 是「**每单元（组合×尺寸）**的种子上限」，每个 seed 至多产 1 关，
# 故要填满 4 档 × PER_TIER 需要 ~PER_TIER×10 次尝试（按实测进档率；服务器链实测每档 100 关用 1200 上下）。
# 旧默认 40 会让每单元最多 40 关 → 集**永远填不满且不报错**（静默薄集，2026-09-19 修正）。
# 要限定预算就显式给：SEED_MAX=1200 ./tools/fill_level_lib.sh
if [ "$SEED_MAX" -le 0 ]; then
  SEED_MAX=$(( PER_TIER * 10 ))
  if [ "$SEED_MAX" -lt 40 ]; then SEED_MAX=40; fi
fi
echo "=== 环境：${CORES} 核 → ${SHARDS} 分片，每档 ${PER_TIER} 关，每单元 seed 上限 ${SEED_MAX} ==="
if [ "$SHARDS" -gt "$CORES" ]; then
  echo "⚠️  分片数 $SHARDS > 核数 $CORES：多个 Godot 进程会互相抢 CPU，反而更慢。" >&2
  echo "   （已知教训：6 分片跑 2 核，44 分钟只完成 per_type=10 的小批量且大量 partial）" >&2
fi

# —— 口径自检（唯一的「开跑前闸门」）——
echo "=== 口径自检（不生成任何关卡）==="
CHECK="$("$GODOT" --headless --path . -s tools/batch_all_variants.gd -- \
  "$OUT_DIR" "$PER_TIER" "$SEED_MAX" -2 0 "$SHARDS" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
printf '%s\n' "$CHECK" | grep -E "观测轴|结构轴|守恒轴|组合总数|口径自检" || true
if ! printf '%s\n' "$CHECK" | grep -q "官方三轴"; then
  echo "❌ 口径自检未通过 —— 先 git pull 到最新（需含口径自检的版本），再重跑本脚本。" >&2
  exit 1
fi
echo "✅ 口径自检通过（官方三轴 164 组合）"
# 注：这里必须用 if 而不是 `[ ... ] && { ...; }` —— 在 set -e 下后者条件为假时整条
# 列表返回非零且不在条件上下文，脚本会**直接退出**（不跑量产），是经典坑。
if [ "$CHECK_ONLY" = "1" ]; then
  echo "（-c：只看自检，未跑量产）"
  exit 0
fi

# —— A 阶段：量产（分片并行，断点续跑）——
echo "=== 量产：${SHARDS} 分片并行（每档 ${PER_TIER} 关；日志 shard_N.log）==="
PIDS=()
for ((i = 0; i < SHARDS; i++)); do
  "$GODOT" --headless --path . -s tools/batch_all_variants.gd -- \
    "$OUT_DIR" "$PER_TIER" "$SEED_MAX" 0 "$i" "$SHARDS" 1 0 "" "" \
    "$PER_TIER" "$TIMEOUT_COEF" tiered "$STALL_MAX" > "shard_${i}.log" 2>&1 &
  PIDS+=("$!")
  sleep 1   # 错开启动，避免同时初始化抢 IO
done
echo "已启动 ${#PIDS[@]} 个分片（PID: ${PIDS[*]}）"
echo "进度：tail -f shard_0.log"
echo "      （心跳行：每个单元完成即落一行 unit_done 到 user://batch_all/issues_shard_*.jsonl，"
echo "        进程被杀也不丢已完成单元；重跑本脚本自动跳过满额单元）"
wait
echo "=== 全部分片结束；产物在 ${OUT_DIR} ==="
echo "下一步（在开发机）：拉回产物 → fill_level_lib.ps1 -SkipBatch -DryRunOnly 先看报告 → 正式导入"
