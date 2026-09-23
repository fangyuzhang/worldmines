export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server
echo '=== batch dirs ==='
ls -d $B/batch_* 2>/dev/null | xargs -n1 basename
echo '=== 各目录: 总关数 + 档位分布 ==='
for d in $(ls -d $B/batch_* 2>/dev/null); do
  n=$(find "$d" -name '*.json' 2>/dev/null | grep -v report | wc -l)
  [ "$n" = "0" ] && continue
  line="$(basename $d): total=$n"
  for t in intro easy normal hard; do
    c=$(find "$d" -name "${t}_*.json" 2>/dev/null | wc -l)
    line="$line $t=$c"
  done
  echo "  $line"
done
echo '=== issues 尾部（unit_done: combo/side/tried/made，判断续跑起点）==='
for f in $B/batch_*/issues*.jsonl; do
  [ -f "$f" ] || continue
  echo "--- $(basename $(dirname $f)) ---"
  grep unit_done "$f" 2>/dev/null | tail -8 | sed 's/.*"attempts"//; s/,"brep_fail".*"made"//; s/,"mines.*"side"/ side/; s/,"similar.*$//'
done
echo GAP_STATE_DONE
