#!/bin/bash
# 收割 0922：打包「本地未收」的 16 个批次（merged ×3 + s1-s7 + z1-z5）
# 设计点：用 xz 压到最小（传输通道按 12KB/片，包越小越快）；已有包则跳过重压。
B=/root/.local/share/godot/app_userdata/wm_server
OUT=/root/harvest_0922.tar.xz
BATCHES="batch_o1_merged batch_o2_merged batch_o3_merged batch_s1 batch_s2 batch_s3 batch_s4 batch_s5 batch_s6 batch_s7 batch_z1 batch_z2 batch_z3 batch_z4 batch_z5"

echo "=== 待打包批次与规模 ==="
tot=0
for d in $BATCHES; do
  n=$(find "$B/$d" -name '*.json' -not -name '*report*' 2>/dev/null | wc -l)
  tot=$((tot + n))
  printf "  %-18s %s\n" "$d" "$n"
done
echo "合计关卡: $tot"

echo "=== 压缩工具 ==="
if command -v xz >/dev/null 2>&1; then
  echo "xz 可用"
  rm -f "$OUT"
  tar -cJf "$OUT" -C "$B" $BATCHES
else
  echo "无 xz，退化为 gzip -9"
  OUT=/root/harvest_0922.tar.gz
  rm -f "$OUT"
  tar --use-compress-program='gzip -9' -cf "$OUT" -C "$B" $BATCHES
fi

echo "=== 产物 ==="
ls -la "$OUT"
stat -c '%s' "$OUT"
md5sum "$OUT"
echo PACK_0922_DONE
