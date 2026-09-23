#!/bin/bash
# 打包已完成补产产物（排除仍在跑的 fill_v41_o9_easy，避免读到半写文件）
B=/root/.local/share/godot/app_userdata/wm_server
OUT=/root/fill_harvest_0923.tar.xz
cd "$B" || exit 1
DIRS=""
for d in fill_v41_*; do
  [ -d "$d" ] || continue
  [ "$d" = "fill_v41_o9_easy" ] && continue
  DIRS="$DIRS $d"
done
echo "=== 打包清单 ==="
TOT=0
for d in $DIRS; do
  n=$(find "$d" -name '*.json' | wc -l)
  TOT=$((TOT + n))
  printf "  %-24s %s\n" "$d" "$n"
done
echo "  合计 $TOT 关（排除 fill_v41_o9_easy：进行中）"
rm -f "$OUT"
tar -cJf "$OUT" -C "$B" $DIRS
echo "=== 产物 ==="
ls -la "$OUT"
stat -c '%s' "$OUT"
md5sum "$OUT"
echo PACK_FILL2_DONE
