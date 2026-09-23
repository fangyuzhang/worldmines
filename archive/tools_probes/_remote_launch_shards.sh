#!/bin/bash
# 分片并行启动（多核利用）：同一 (组合,尺寸) 单元按 seed 段拆 N 个进程，各自独立 out 目录。
# 用法：_launch_shards.sh <base> <spec> <mods> <n_shards> <per_tier_total> [coef] [seg_size]
# 例：  _launch_shards.sh batch_o2_57 "o2@5-7" o2_linxu 8 100 3000 1000
# 合并：产物用 tools/merge_shards.ps1 汇总（指纹去重 + 按难度取前 N + 重编号）
export HOME=/root
cd /root/minesweeper
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
export GODOT_SILENCE_ROOT_WARNING=1
BASE="$1"; SPEC="$2"; MODS="$3"; N="$4"; PER_TOTAL="$5"; COEF="${6:-3000}"; SEG="${7:-1000}"
if [ -z "$BASE" ] || [ -z "$SPEC" ] || [ -z "$N" ]; then
  echo "用法: _launch_shards.sh <base> <spec> <mods> <n_shards> <per_tier_total> [coef] [seg_size]"
  exit 1
fi
# 每段配额：总量/N 再乘 1.3 冗余（难度分布不均，合并时按难度取前 N 裁剪）
PER=$(( (PER_TOTAL + N - 1) / N ))
PER=$(( PER * 13 / 10 ))
[ "$PER" -lt 4 ] && PER=4
echo "shards=$N seg=$SEG per_tier_per_shard=$PER coef=$COEF"
for i in $(seq 0 $((N - 1))); do
  S=$((1 + i * SEG))
  E=$((S + SEG - 1))
  OUT="user://${BASE}_s$i"
  rm -rf "/root/.local/share/godot/app_userdata/wm_server/${BASE}_s$i"
  nohup $G --headless --path . -s res://tools/batch_all_variants.gd -- "$OUT" 10 "$E" -1 1 1 "$S" 0 "$SPEC" "$MODS" "$PER" "$COEF" > "/root/gen_${BASE}_s$i.log" 2>&1 &
  echo "  shard $i: seed $S..$E -> $OUT"
done
sleep 25
echo "=== procs ==="
pgrep -af batch_all_variants | head -6 | cut -c1-100
echo "=== files ==="
for i in $(seq 0 $((N - 1))); do
  printf 's%s: ' "$i"
  find "/root/.local/share/godot/app_userdata/wm_server/${BASE}_s$i" -name '*.json' 2>/dev/null | wc -l
done
echo LAUNCH_SHARDS_DONE
