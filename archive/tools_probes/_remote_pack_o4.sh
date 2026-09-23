#!/bin/bash
# 2026-09-17 晚收割：batch_o4（1559 关）。
# 注：report.ok=1339 是上一轮运行报告（本轮被挂死后人工终止，未写新报告）——
#     完整性由门禁逐盘 JSON 解析兜底，不做 ok==实数 检查。
export HOME=/root
cd /root/minesweeper
B=/root/.local/share/godot/app_userdata/wm_server
OUT=/root/harvest_0917_o4.tar.gz
rm -f "$OUT"
n=$(find $B/batch_o4 -name '*.json' | grep -v report | wc -l)
echo "batch_o4 关数: $n"
tar -czf "$OUT" -C "$B" batch_o4
md5sum "$OUT"
ls -l "$OUT"
echo '=== 确认 lane Godot 已起（应为 2）==='
ps -eo comm= | grep -c '^Godot'
grep -E '^--- \[' /root/gen_chain_A.log | tail -1
grep -E '^--- \[' /root/gen_chain_B.log | tail -1
echo PACK_O4_DONE
