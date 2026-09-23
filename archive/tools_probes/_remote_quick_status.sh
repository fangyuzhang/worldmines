export HOME=/root
echo "procs: $(pgrep -fc godot)"
echo '=== counts ==='
echo "o4: $(find /root/.local/share/godot/app_userdata/wm_server/batch_o4 -name '*.json' 2>/dev/null | wc -l)"
echo "o5x: $(find /root/.local/share/godot/app_userdata/wm_server/batch_o5x -name '*.json' 2>/dev/null | wc -l)"
echo "o8: $(find /root/.local/share/godot/app_userdata/wm_server/batch_o8 -name '*.json' 2>/dev/null | wc -l)"
echo '=== new since restart (13:00) ==='
echo "o4 new: $(find /root/.local/share/godot/app_userdata/wm_server/batch_o4 -name '*.json' -newermt '2026-09-15 13:00' 2>/dev/null | wc -l)"
echo "o5x new: $(find /root/.local/share/godot/app_userdata/wm_server/batch_o5x -name '*.json' -newermt '2026-09-15 13:00' 2>/dev/null | wc -l)"
echo "o8 new: $(find /root/.local/share/godot/app_userdata/wm_server/batch_o8 -name '*.json' -newermt '2026-09-15 13:00' 2>/dev/null | wc -l)"
echo '=== o8 tail ==='
tail -3 /root/gen_o8.log
echo '=== o5x tail ==='
tail -3 /root/gen_o5x2.log
echo '=== o4 tail ==='
tail -3 /root/gen_o4.log
echo QUICK_STATUS_DONE
