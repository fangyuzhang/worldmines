#!/bin/bash
# 2026-09-17 收割打包：第一轮已完成的 4 批（o10 / o5x / o8 / o9）。
# o4 仍在写（report ok=1339 < 实际 1559），不采；补产链 12 批未启动。
export HOME=/root
cd /root/minesweeper
B=/root/.local/share/godot/app_userdata/wm_server
OUT=/root/harvest_0917.tar.gz
rm -f "$OUT"
echo '=== 采集前一致性检查（report.ok == 实际 json 数）==='
for b in batch_o10 batch_o5x batch_o8 batch_o9; do
  d="$B/$b"
  n=$(find "$d" -name '*.json' | grep -v report | wc -l)
  ok=$(python3 -c "import json;print(json.load(open('$d/all_report.json'))['stats']['ok'])" 2>/dev/null)
  if [ "$n" = "$ok" ]; then echo "  $b: $n == $ok OK"; else echo "  $b: $n != $ok MISMATCH -> ABORT"; exit 1; fi
done
tar -czf "$OUT" -C "$B" batch_o10 batch_o5x batch_o8 batch_o9
md5sum "$OUT"
ls -l "$OUT"
echo PACK_DONE
