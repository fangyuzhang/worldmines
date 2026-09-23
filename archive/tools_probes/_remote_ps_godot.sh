export HOME=/root
echo '=== all godot procs ==='
ps -eo pid,ppid,etime,rss,cmd | grep -i godot | grep -v grep
echo '=== batch tasks count ==='
pgrep -fc batch_all_variants
echo PS_DONE
