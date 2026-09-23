#!/bin/bash
# 服务器：日志错误扫描（盲区⑧——push_error 静默降级/崩溃痕迹，人工翻日志才发现的问题类型）
export HOME=/root
echo "=== SCRIPT ERROR / ERROR 计数（各分片日志）==="
for f in /root/gen_shard_0.log /root/gen_shard_1.log; do
  [ -f "$f" ] || continue
  n=$(grep -c "SCRIPT ERROR" "$f" 2>/dev/null || echo 0)
  e=$(grep -cE "^(ERROR|ERROR:)" "$f" 2>/dev/null || echo 0)
  echo "$(basename $f): SCRIPT_ERROR=$n ERROR=$e"
done
echo "=== 错误分类（去重后前 15 类）==="
cat /root/gen_shard_0.log /root/gen_shard_1.log 2>/dev/null \
  | grep -E "SCRIPT ERROR|ERROR:" \
  | sed -E 's/.*(SCRIPT ERROR|ERROR): //; s/ at:.*//' \
  | sort | uniq -c | sort -rn | head -15
echo "=== 是否有崩溃/OOM ==="
dmesg 2>/dev/null | grep -iE "oom|killed process" | tail -3 || echo "(dmesg 不可用)"
echo SCAN_DONE
