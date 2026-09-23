#!/bin/bash
# 打包补产产物（fill_v41_*）供拉回：xz 压到最小（传输按 12KB/片）
B=/root/.local/share/godot/app_userdata/wm_server
OUT=/root/fill_harvest_0922.tar.xz
cd "$B"
DIRS=""
for d in fill_v41_*; do
  [ -d "$d" ] && DIRS="$DIRS $d"
done
echo "=== 待打包 ==="
for d in $DIRS; do
  printf "  %-24s %s\n" "$d" "$(find "$d" -name '*.json' | wc -l)"
done
echo "=== 压缩 ==="
rm -f "$OUT"
tar -cJf "$OUT" -C "$B" $DIRS
ls -la "$OUT"
stat -c '%s' "$OUT"
md5sum "$OUT"
echo PACK_FILL_DONE
