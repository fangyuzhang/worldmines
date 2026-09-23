export HOME=/root
cd /root/minesweeper
DIR=/root/.local/share/godot/app_userdata/wm_server/batch_o5x/x_o5x/8x8
echo '=== 8x8 files (mtime, name) ==='
find $DIR -name '*.json' -printf '%TY-%Tm-%Td %TH:%TM %f\n' 2>/dev/null | sort | tail -40
echo '=== verify 8x8 ==='
timeout 880 /opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64 --headless --path . -s res://tools/verify_batch.gd -- user://batch_o5x/x_o5x/8x8 > /root/verify_o5x_8.log 2>&1
tail -15 /root/verify_o5x_8.log
echo O5X_V8_DONE
