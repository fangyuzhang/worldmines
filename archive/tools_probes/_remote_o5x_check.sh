export HOME=/root
echo '=== procs ==='
pgrep -fc batch_all_variants
echo '=== o5x dir files by tier ==='
cd /root/.local/share/godot/app_userdata/wm_server/batch_o5x 2>/dev/null || exit 0
find . -name '*.json' | sed 's|.*/||' | cut -d_ -f1 | sort | uniq -c
echo '=== o5x dirs ==='
find . -type d | sort | head -12
echo '=== o5x log tail ==='
tail -5 /root/gen_o5x2.log
echo O5X_CHECK_DONE
