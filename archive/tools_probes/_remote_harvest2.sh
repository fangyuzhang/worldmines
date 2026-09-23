#!/bin/bash
# 收割 2：o4（主目标，上次未含）+ o5x（增量）+ o1_7/o1_8（最新态）。
# 说明：o8 仍在跑不收；batch_all 3597 关已收过（wm_results_20260913.tar.gz）。
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server
cd /root
rm -f /root/wm_harvest_0915b.tar.gz
tar -czf /root/wm_harvest_0915b.tar.gz -C "$B" batch_o4 batch_o5x batch_o1_7 batch_o1_8
echo '=== size ==='
ls -la /root/wm_harvest_0915b.tar.gz
echo '=== md5 ==='
md5sum /root/wm_harvest_0915b.tar.gz
echo '=== per-dir counts ==='
for d in batch_o4 batch_o5x batch_o1_7 batch_o1_8; do
  n=$(find "$B/$d" -name '*.json' 2>/dev/null | wc -l)
  i=$(find "$B/$d" -name 'intro_*.json' 2>/dev/null | wc -l)
  echo "$d: json=$n intro=$i"
done
echo HARVEST2_DONE
