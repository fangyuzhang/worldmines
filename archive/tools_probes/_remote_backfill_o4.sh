export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
B=/root/.local/share/godot/app_userdata/wm_server
echo '=== 确认无进程写 batch_o4（当前 lane 应是 o1/o2）==='
grep -E '^--- \[' /root/gen_chain_A.log | tail -1
grep -E '^--- \[' /root/gen_chain_B.log | tail -1
echo '=== 回填前：batch_o4 缺 hidden_state 关数 ==='
n_total=$(find $B/batch_o4 -name '*.json' | grep -v report | wc -l)
n_with=$(grep -rl 'hidden_state' $B/batch_o4 --include='*.json' 2>/dev/null | grep -v report | wc -l)
echo "总 $n_total / 有字段 $n_with / 缺失 $((n_total - n_with))"
echo '=== 跑回填（幂等）==='
$G --headless --path . -s res://tools/_backfill_hidden_state.gd -- "$B/batch_o4" 2>&1 | tail -2
echo '=== 回填后核验 ==='
n_with2=$(grep -rl 'hidden_state' $B/batch_o4 --include='*.json' 2>/dev/null | grep -v report | wc -l)
echo "总 $n_total / 有字段 $n_with2 / 缺失 $((n_total - n_with2))"
echo '=== lane 进度抽查 ==='
find $B/batch_o1_merged -name '*.json' 2>/dev/null | grep -v report | wc -l
find $B/batch_o2_merged -name '*.json' 2>/dev/null | grep -v report | wc -l
echo SERVER_BACKFILL_O4_DONE
