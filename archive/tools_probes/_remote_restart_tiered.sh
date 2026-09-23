export HOME=/root
cd /root/minesweeper
GODOT=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
echo '=== kick old tasks ==='
pkill -f batch_all_variants
sleep 4
echo "procs left: $(pgrep -fc godot)"
echo '=== restart with tiered + stall30 ==='
nohup $GODOT --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o4 10 400 -1 1 1 0 0 o4@6-9 o4_bianjing 100 3000 tiered 30 >> /root/gen_o4.log 2>&1 &
nohup $GODOT --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o5x 10 400 -1 1 1 0 0 o5x@5-9 o5_xiemai 30 3000 tiered 30 >> /root/gen_o5x2.log 2>&1 &
nohup $GODOT --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o8 10 400 -1 1 1 0 0 o8@5-9 o8_zhongdian 50 3000 tiered 30 >> /root/gen_o8.log 2>&1 &
sleep 25
echo "procs after: $(pgrep -fc godot)"
echo '=== verify mods loaded ==='
grep -c '已加载' /root/gen_o4.log
tail -1 /root/gen_o8.log
echo RESTART_TIERED_DONE
