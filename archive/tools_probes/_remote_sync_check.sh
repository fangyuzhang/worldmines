cd /root/minesweeper
echo '=== 服务器 puzzle_generator.gd 是否有隐藏态导出 ==='
grep -n 'export_hidden_state' core/puzzle_generator.gd | head -5
echo '=== 服务器 board.gd 是否有隐藏态恢复 ==='
grep -n 'import_hidden_state\|hidden_state' core/board.gd | head -5
echo '=== 服务器 o5x mod 是否有 export/import ==='
ls demo/mods/ | grep -i 'o5'
for m in demo/mods/o5*/; do
  echo "--- $m ---"
  grep -c 'export_hidden_state\|import_hidden_state' "$m/entry.gd" 2>/dev/null || echo '  无匹配'
done
echo '=== 服务器 batch_o5x 新盘有无 hidden_state（抽 3 个）==='
B=/root/.local/share/godot/app_userdata/wm_server
n_total=$(find $B/batch_o5x -name '*.json' | grep -v report | wc -l)
n_with=$(grep -rl 'hidden_state' $B/batch_o5x --include='*.json' 2>/dev/null | grep -v report | wc -l)
echo "batch_o5x: 总 $n_total / 含 hidden_state $n_with"
echo '=== 服务器 batch_o4（在跑）抽样 ==='
n4_total=$(find $B/batch_o4 -name '*.json' | grep -v report | wc -l)
n4_with=$(grep -rl 'hidden_state' $B/batch_o4 --include='*.json' 2>/dev/null | grep -v report | wc -l)
echo "batch_o4: 总 $n4_total / 含 hidden_state $n4_with"
echo '=== o4 mod 隐藏态方法 ==='
for m in demo/mods/o4*/; do echo "--- $m ---"; grep -c 'export_hidden_state' "$m/entry.gd" 2>/dev/null || echo '  无'; done
echo SYNC_CHECK_DONE
