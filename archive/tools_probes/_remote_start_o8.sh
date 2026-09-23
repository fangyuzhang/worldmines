export HOME=/root
cd /root/minesweeper
nohup /opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64 --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o8 10 400 -1 1 1 0 0 o8@5-9 o8_zhongdian 50 > /root/gen_o8.log 2>&1 &
echo "started pid=$!"
sleep 25
echo '=== log check ==='
head -10 /root/gen_o8.log
echo '=== procs now ==='
pgrep -fc godot
echo O8_START_DONE
