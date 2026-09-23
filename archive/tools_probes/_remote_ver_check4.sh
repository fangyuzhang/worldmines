#!/bin/bash
R=/root/minesweeper
echo "=== 服务器 batch 工具是否含候选雷数回退 / resolve_mines ==="
grep -n "resolve_mines\|CANDIDATES\|fallback\|候选回退" $R/tools/batch_all_variants.gd | head -8
echo "(空 = 无回退逻辑)"
echo
echo "=== 服务器 core/rule_feasibility.gd 是否存在 & 候选表 ==="
if [ -f $R/core/rule_feasibility.gd ]; then
  md5sum $R/core/rule_feasibility.gd
  grep -n "CANDIDATES" $R/core/rule_feasibility.gd | head -5
else
  echo "MISSING core/rule_feasibility.gd"
fi
echo
echo "=== 服务器 puzzle_generator 的 get_kind 命中位置（确认 KIND 路由是否真存在）==="
grep -n "get_kind\|KIND_CLUE" $R/core/puzzle_generator.gd | head -6
echo
echo "=== 正在跑的链的完整参数（lane 行）==="
grep -n "BGD\|Godot\|args" /root/gap_chain.sh | head -12 | cut -c1-200
