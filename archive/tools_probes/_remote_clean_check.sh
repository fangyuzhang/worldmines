export HOME=/root
kill 2842409 2842412 2>/dev/null
sleep 2
echo "godot procs: $(pgrep -fc godot)"
echo '=== o4 log ==='
tail -2 /root/gen_o4.log
echo '=== o5x log ==='
tail -2 /root/gen_o5x2.log
echo '=== o8 log ==='
tail -2 /root/gen_o8.log
echo CLEAN_DONE
