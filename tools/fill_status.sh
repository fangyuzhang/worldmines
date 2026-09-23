#!/bin/bash
# 补齐上次被截断的部分：各轮「完成：共产出 N 关」汇总 + 各目录合计
B=/root/.local/share/godot/app_userdata/wm_server
echo "=== 各轮完成汇总（链日志）==="
grep -E '完成：共产出|^--- \[' /root/fill_chain.log | sed 's/^--- //'
echo "=== 各目录合计（含首发）==="
for d in "$B"/fill_v41_*; do
  [ -d "$d" ] || continue
  printf "%-24s %s\n" "$(basename "$d")" "$(find "$d" -name '*.json' | wc -l)"
done
echo "=== 总量 ==="
find "$B" -path '*fill_v41_*' -name '*.json' | wc -l
echo FILL_STATUS3_DONE
