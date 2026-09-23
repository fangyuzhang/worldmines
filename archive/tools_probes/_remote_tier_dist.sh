export HOME=/root
f=/root/.local/share/godot/app_userdata/wm_server/batch_o5x/issues.jsonl
echo '=== o5x tier_empty side distribution ==='
grep '"t":"tier_empty"' $f | grep -o '"side":[0-9]*' | sort | uniq -c | sort -rn
echo '=== o5x tier_empty diff distribution ==='
grep '"t":"tier_empty"' $f | grep -o '"diff":[0-9.]*' | cut -d: -f2 | sort -n | awk 'NR==1{min=$1} {a[NR]=$1; s+=$1} END {print "n="NR, "min="min; print "p10="a[int(NR*0.1)+1], "p50="a[int(NR*0.5)+1], "p90="a[int(NR*0.9)+1], "max="a[NR]; print "avg="s/NR}'
echo '=== o4 tier_empty diff list ==='
f4=/root/.local/share/godot/app_userdata/wm_server/batch_o4/issues.jsonl
grep '"t":"tier_empty"' $f4 | grep -o '"diff":[0-9.]*' | cut -d: -f2 | sort -n | head -20
echo DIST_DONE
