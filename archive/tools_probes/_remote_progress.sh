export HOME=/root
echo '=== procs ==='
pgrep -fc batch_all_variants
echo '=== dirs ==='
for d in /root/.local/share/godot/app_userdata/wm_server/batch_*; do
  [ -d "$d" ] || continue
  n=$(find "$d" -name '*.json' 2>/dev/null | wc -l)
  e=$(find "$d" -name 'easy_*.json' 2>/dev/null | wc -l)
  no=$(find "$d" -name 'normal_*.json' 2>/dev/null | wc -l)
  h=$(find "$d" -name 'hard_*.json' 2>/dev/null | wc -l)
  echo "$(basename $d): total=$n easy=$e normal=$no hard=$h"
done
echo '=== logs tail ==='
for f in /root/gen_o2_57.log /root/gen_o2_8.log /root/gen_o3.log /root/gen_o4.log /root/gen_o1b_7.log /root/gen_o1b_8.log; do
  echo "--- $(basename $f) ---"
  tail -2 "$f" 2>/dev/null
done
echo '=== done ==='
