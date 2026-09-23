export HOME=/root
cd /root/minesweeper
GODOT=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
echo '=== kill old tasks ==='
pkill -f batch_all_variants
sleep 4
echo "procs left: $(pgrep -fc godot)"
echo '=== restart o4 ==='
nohup $GODOT --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o4 10 400 -1 1 1 0 0 o4@6-9 o4_bianjing 100 >> /root/gen_o4.log 2>&1 &
echo '=== restart o5x ==='
nohup $GODOT --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o5x 10 400 -1 1 1 0 0 o5x@5-9 o5_xiemai 30 >> /root/gen_o5x2.log 2>&1 &
echo '=== restart o8 ==='
nohup $GODOT --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o8 10 400 -1 1 1 0 0 o8@5-9 o8_zhongdian 50 >> /root/gen_o8.log 2>&1 &
sleep 25
echo '=== procs after ==='
pgrep -fc godot
echo '=== o8 tail ==='
tail -4 /root/gen_o8.log
echo '=== o5x tail ==='
tail -3 /root/gen_o5x2.log
echo RESTART_DONE
