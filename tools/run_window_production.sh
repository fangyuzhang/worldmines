#!/bin/bash
# 窗口模式补产（难度体系 v4.0）：按「峰值深度窗口」定向补产某一档的关卡。
#
# 用法（在 /root/minesweeper 下）：
#   bash tools/run_window_production.sh <tag> <窗口 lo-hi> <组合规格> <输出目录> [per_tier] [seed_max] [mods]
# 例：
#   bash tools/run_window_production.sh o4_nm "9-20" "o4@5-9" user://batch_w4_o4 100 1200 o4_bianjing
#   bash tools/run_window_production.sh s1_nm "9-20" "classic+s1@7-9" user://batch_w4_s1 100 1200 s1_jinxing
#
# 运维注意（血泪）：
#   ① 窗口模式要求输出目录「口径干净」——目录里若含旧口径文件（峰值不在窗口内）会**拒绝续跑**并报错，
#      防的是继承错误档位计数导致 made=0 且看起来像"窗口太严"。换新目录或先清理。
#   ② 空缺参数位必须填占位值（tiered 填 off、k 旋钮填 -1）——PowerShell/参数错位会让窗口静默失效。
#   ③ 建议在现有补产链结束后启动：2 核满载时并行会让两边都变慢（2026-09-19 实测 load 2.52/2 核）。
#   ④ 单候选成本实测 2.5s(z1@8) / 6.6s(s1@8) / 17.1s(o4@8)；命中率 0%(o8)/10%(s1)/56%(o4)。
#      据此估机时：100 关噩梦 ≈ 1.8h（s1@8）/ 0.8h（o4@8）。
set -e

TAG="${1:?用法: run_window_production.sh <tag> <窗口 lo-hi> <组合规格> <输出目录> [per_tier] [seed_max] [mods]}"
WIN="${2:?缺少窗口，如 9-20}"
SPEC="${3:?缺少组合规格，如 o4@5-9 或 classic+s1@7-9}"
OUT="${4:?缺少输出目录，如 user://batch_w4_o4}"
PER_TIER="${5:-100}"
SEED_MAX="${6:-1200}"
MODS="${7:-}"

G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
LOG="/root/gen_window_${TAG}.log"

cd /root/minesweeper
echo "--- [$TAG] start $(date '+%F %H:%M:%S') 窗口=$WIN 规格=$SPEC 输出=$OUT per_tier=$PER_TIER mods=$MODS ---" | tee -a "$LOG"
# 参数位：out per_type seed_max limit shard_idx shard_total seed_start target spec mods per_tier coef tiered stall k 窗口
"$G" --headless --path . -s res://tools/batch_all_variants.gd -- \
	"$OUT" "$PER_TIER" "$SEED_MAX" -1 1 1 0 0 "$SPEC" "$MODS" "$PER_TIER" 3000 off 60 -1 "$WIN" >> "$LOG" 2>&1
echo "--- [$TAG] done $(date '+%F %H:%M:%S') ---" | tee -a "$LOG"
echo "[提示] 产物在 $OUT/<combo>/<SxS>/；用 tools/import_batch_to_lib.gd 入库（窗口一致性校验会自动拦截错档）"
