#!/bin/bash
# _status_probe.sh —— 服务器补产链进度速报（本地经 TAT runfile 执行；不入 git）
# 输出：各批次关数 + 双 lane 日志尾部（含单元进度行），供估算剩余时间。
B=/root/.local/share/godot/app_userdata/wm_server
echo "===BATCH_COUNTS==="
total=0
for d in "$B"/batch_*; do
  [ -d "$d" ] || continue
  n=$(find "$d" -name '*.json' ! -name '*report*' 2>/dev/null | wc -l)
  total=$((total + n))
  echo "$(basename "$d") $n"
done
echo "---TOTAL $total ..."
echo "===LANEA-TAIL==="
tail -20 /root/gen_chain_A.log
echo "===LANEB-TAIL==="
tail -20 /root/gen_chain_B.log
echo "===TAIL-DONE==="
