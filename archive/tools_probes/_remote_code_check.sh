export HOME=/root
cd /root/minesweeper 2>/dev/null || cd /root/wm 2>/dev/null || { echo "!! 项目目录未找到"; ls /root; exit 1; }
echo "=== pwd ==="
pwd
echo "=== git log -3 ==="
git --no-pager log --oneline -3 2>&1
echo "=== git status（前 10 行）==="
git status --porcelain 2>&1 | head -10
echo "=== 本地关键文件是否含新特性 ==="
grep -c "mask_pre" core/puzzle_generator.gd 2>/dev/null && echo "  mask_pre 命中（遮蔽前置已在服务器）" || echo "  mask_pre 未命中（服务器为旧版）"
grep -c "CLUE_RATIO_OUTLIER_DELTA" tools/verify_batch.gd 2>/dev/null && echo "  门禁相对口径已同步" || echo "  门禁为旧版"
echo "=== 关键脚本存在性 ==="
ls -la tools/batch_all_variants.gd tools/verify_batch.gd 2>&1 | head -4
echo CODE_CHECK_DONE
