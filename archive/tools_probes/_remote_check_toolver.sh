#!/bin/bash
# 收割/补产前置检查：服务器侧工具是否支持 v4.1 三档窗口（第 16 参）与启动器
cd /root/minesweeper
echo "=== git 版本 ==="
git --no-pager log --oneline -1 2>/dev/null
echo "=== 量产工具是否支持第 16 参窗口 ==="
grep -c "_peak_window" tools/batch_all_variants.gd 2>/dev/null
grep -n "第 16 参" tools/batch_all_variants.gd 2>/dev/null | head -3
echo "=== 启动器是否存在 ==="
ls -la tools/run_window_production.sh 2>/dev/null || echo "（无 run_window_production.sh）"
echo "=== core 判据版本（应为三档 2-3/4-5/6-20）==="
grep -n -A6 "const PEAK_WINDOWS" core/difficulty.gd 2>/dev/null | head -10
echo CHECK_DONE
