#!/bin/bash
# fill_chain.sh —— 按薄集优先级**串行**补产（每轮先等空闲核，绝不与现有补产链抢核）
#
# ⚠️ 已被 tools/fill_level_lib.sh（2026-09-22，`8e45386`）取代——那个是项目自带的**增量补库**入口：
#    口径自检 + 分片 + 心跳续跑（unit_done → 重跑自动跳过满额单元）+ 可配 PER_TIER/SEED_MAX。
#    本脚本保留为「按窗口定向补产单席单档」的历史工具（首发 s1 与 s6/s4/o5x/s3/z4 的噩梦批次由它产出，
#    共 1,988 关，见 `待办项.md`）；新排产请用 fill_level_lib.sh。
#
# 依据：tools/thin_cells.py 的优先级（hard@7-9 缺口最大 → 再普通/困难档，后者便宜）
# 纪律：全部走窗口验收（fill_window.gd 内建校验：坏格式启动即失败、不落盘窗口外关卡）
# 观测：/root/fill_chain.log（每轮 start/done + 命中率/峰值分布由工具自打印）
cd /root/minesweeper || exit 1
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
LOG=/root/fill_chain.log
NCORE=$(nproc)

# 等空闲核：现有 Godot 进程数 < 核数 才开工（s7 与 gap 链优先）
wait_core() {
  while [ "$(ps -eo comm= | grep -c '^Godot')" -ge "$NCORE" ]; do sleep 120; done
}

run() {  # <tag> <clue> <globals|-> <sizes> <lo> <hi> <per_side> <max_cand> <budget_s> <mods|-> <out>
  local tag="$1" clue="$2" glob="$3" sizes="$4" lo="$5" hi="$6" per="$7" maxc="$8" bud="$9" mods="${10}" out="${11}"
  wait_core
  echo "--- [$tag] start $(date '+%F %H:%M:%S') 窗口 $lo-$hi 尺寸 $sizes mods=$mods ---" >> "$LOG"
  "$G" --headless --path . -s res://tools/fill_window.gd -- \
    "$clue" "$glob" "$sizes" "$lo" "$hi" "$per" "$maxc" "$bud" "$mods" "$out" >> "$LOG" 2>&1
  echo "--- [$tag] done $(date '+%F %H:%M:%S') ---" >> "$LOG"
}

echo "=== 补产链启动 $(date '+%F %H:%M:%S')（$NCORE 核，等空闲核）===" >> "$LOG"

# 第一批：噩梦 @7-9（缺口最大；s1 已由首发跑 7/8/9，这里补其余深变体）
run s6_hard   classic s6   7,8,9 6 20 100 3000 5400 s6_duou     user://fill_v41_s6_hard
run s4_hard   classic s4   7,8,9 6 20 100 3000 5400 s4_yangcong  user://fill_v41_s4_hard
run o5x_hard  o5x     -    7,8,9 6 20 100 3000 5400 o5_xiemai    user://fill_v41_o5x_hard
run s3_hard   classic s3   7,8,9 6 20 100 3000 5400 s3_wuhuan    user://fill_v41_s3_hard
run z4_hard   classic z4   7,8,9 6 20 100 3000 5400 z4_hangliesu user://fill_v41_z4_hard

# 第二批：便宜档（普通 2-3 / 困难 4-5）——命中率高、单价低，把 1-2 关的薄集填满
run dt_norm   classic dt   5,6,7,8,9 4 5 100 800 1800 - user://fill_v41_dt_normal
run dt_easy   classic dt   5,6,7,8,9 2 3 100 800 1800 - user://fill_v41_dt_easy
run o4_norm   o4      -    5,6,7 4 5 100 800 2400 o4_bianjing user://fill_v41_o4_normal
run o9_easy   o9      -    6,7,8,9 2 3 100 800 2400 o9_sheju user://fill_v41_o9_easy
run o10_easy  o10     -    5,6,7,8,9 2 3 100 800 2400 o10_huanyou user://fill_v41_o10_easy

echo "FILL_CHAIN_DONE $(date '+%F %H:%M:%S')" >> "$LOG"
