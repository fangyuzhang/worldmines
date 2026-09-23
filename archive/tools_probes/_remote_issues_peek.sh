export HOME=/root
for t in o4 o5x o8; do
  echo "=== $t issues tail ==="
  tail -2 /root/.local/share/godot/app_userdata/wm_server/batch_$t/issues.jsonl 2>/dev/null | cut -c1-220
done
echo '=== cpu ==='
ps -eo pid,etime,pcpu,rss,cmd | grep batch_all | grep -v grep | cut -c1-120
echo ISSUES_DONE
