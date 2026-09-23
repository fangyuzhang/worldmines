#!/bin/bash
# 列出服务器产出的全部 batch_* 目录与规模（决定收割范围）
B=/root/.local/share/godot/app_userdata/wm_server
echo "=== 根目录 ==="
ls -d "$B"/batch_* 2>/dev/null | wc -l
echo "=== 每批次：json 数 / 文件名档位前缀分布 ==="
for d in "$B"/batch_*; do
  [ -d "$d" ] || continue
  n=$(find "$d" -name '*.json' -not -name '*report*' 2>/dev/null | wc -l)
  i=$(find "$d" -name 'intro_*.json' 2>/dev/null | wc -l)
  e=$(find "$d" -name 'easy_*.json' 2>/dev/null | wc -l)
  o=$(find "$d" -name 'normal_*.json' 2>/dev/null | wc -l)
  h=$(find "$d" -name 'hard_*.json' 2>/dev/null | wc -l)
  printf "%-34s json=%-6s intro=%-5s easy=%-5s normal=%-5s hard=%-5s\n" "$(basename "$d")" "$n" "$i" "$e" "$o" "$h"
done
echo "=== 总计 ==="
find "$B" -name '*.json' -not -name '*report*' 2>/dev/null | wc -l
echo "=== 磁盘 ==="
df -h /root | tail -1
