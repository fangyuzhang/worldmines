#!/bin/bash
# 打包补产产物（两个产出族：fill_v41_* 补产链 / thinfill_* curated 薄集计划）供拉回。
#
# 纪律（踩过的坑）：
#   · 自动排除「正在写」的目录——判据=该轮日志 /root/gen_window_<tag>.log 或 /root/fill_*.log
#     在最近 180 秒内被动过；否则 tar 可能读到半写文件（会被 retier 记成坏文件，静默少收）。
#   · xz 压到最小（传输按 12KB 片，压缩率直接决定拉回时间）。
B=/root/.local/share/godot/app_userdata/wm_server
OUT=${1:-/root/harvest_server.tar.xz}
cd "$B" || exit 1

ACTIVE=""
for f in $(ls -t /root/gen_window_*.log /root/fill_*.log 2>/dev/null); do
  [ -n "$(find "$f" -newermt '-180 seconds' 2>/dev/null)" ] || continue
  tag=$(basename "$f" .log | sed 's/^gen_window_//; s/^fill_//')
  ACTIVE="$ACTIVE $tag"
done

DIRS=""
for d in fill_v41_* thinfill_*; do
  [ -d "$d" ] || continue
  skip=0
  for t in $ACTIVE; do
    case "$d" in *"$t"*) skip=1 ;; esac
  done
  if [ "$skip" = "1" ]; then
    echo "  [跳过·进行中] $d"
    continue
  fi
  DIRS="$DIRS $d"
done

echo "=== 打包清单 ==="
TOT=0
for d in $DIRS; do
  n=$(find "$d" -name '*.json' | wc -l)
  TOT=$((TOT + n))
  printf "  %-30s %5s\n" "$d" "$n"
done
echo "  合计 $TOT 关"
rm -f "$OUT"
tar -cJf "$OUT" -C "$B" $DIRS
echo "=== 产物 ==="
ls -la "$OUT"
stat -c '%s' "$OUT"
md5sum "$OUT"
echo PACK_ALL_DONE
