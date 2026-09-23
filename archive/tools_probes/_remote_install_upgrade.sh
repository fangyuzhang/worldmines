#!/bin/bash
# 服务器侧：安装「代码升级（dry-run 默认）」与「z 表外尺寸归档（dry-run 默认）」两个脚本
set -u

echo "=== ① 写 /root/upgrade_code.sh ==="
cat > /root/upgrade_code.sh <<'EOF'
#!/bin/bash
# upgrade_code.sh —— 把服务器代码（core / demo/mods / tools）升级到开发机当前版本。
# 默认 **dry-run**（只报差异）；`--apply` 才真正升级（升级前自动备份到 /root/backup_<stamp>/，
# 升级后跑「口径自检」验证新工具可用）。
# 为什么强调顺序：链在跑时换版会污染产出 —— **只在所有量产进程结束后**执行。
set -euo pipefail
R=/root/minesweeper
M=${MIRROR:-/root/mirror_0919.tar.gz}
STAMP=$(date +%Y%m%d_%H%M%S)
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

[ -f "$M" ] || { echo "镜像不存在: $M" >&2; exit 1; }
if ps -eo comm= | grep -q '^Godot'; then
  echo "⚠️  检测到 Godot 仍在运行 —— 换版会污染在跑的产出。请等量产结束后再执行。" >&2
  [ "$APPLY" = "1" ] && exit 2
fi
TMP="/root/_upgrade_tmp_$STAMP"
mkdir -p "$TMP"
tar -xzf "$M" -C "$TMP"

echo "=== 差异概览（镜像 vs 现网）==="
for d in core demo/mods tools; do
  n=$(diff -rq "$TMP/$d" "$R/$d" 2>/dev/null | grep -c . || true)
  echo "  $d: $n 处差异"
done
echo "--- core 差异明细（前 20）---"
diff -rq "$TMP/core" "$R/core" 2>/dev/null | head -20 || true

if [ "$APPLY" = "0" ]; then
  echo "（dry-run：确认无误后执行  bash /root/upgrade_code.sh --apply）"
  exit 0
fi

echo "=== 备份 → /root/backup_$STAMP/ ==="
mkdir -p "/root/backup_$STAMP"
cp -a "$R/core" "/root/backup_$STAMP/" 2>/dev/null || true
cp -a "$R/tools" "/root/backup_$STAMP/" 2>/dev/null || true
if [ -d "$R/demo/mods" ]; then
  mkdir -p "/root/backup_$STAMP/demo"
  cp -a "$R/demo/mods" "/root/backup_$STAMP/demo/" 2>/dev/null || true
fi

echo "=== 升级 ==="
cp -a "$TMP/core" "$R/"
cp -a "$TMP/tools" "$R/"
mkdir -p "$R/demo"
cp -a "$TMP/demo/mods" "$R/demo/"
rm -rf "$TMP"
echo "已升级（回滚：cp -a /root/backup_$STAMP/core /root/backup_$STAMP/tools $R/）"

echo "=== 口径自检（验证新工具链可用）==="
cd "$R"
"$G" --headless --path . -s tools/batch_all_variants.gd -- user://axis_check 0 1 -2 0 1 2>&1 \
  | sed 's/\x1b\[[0-9;]*m//g' | grep -E "观测轴|结构轴|守恒轴|组合总数|尺寸政策|口径自检" || true
echo "=== 升级完成 ==="
EOF
chmod +x /root/upgrade_code.sh
echo "已写: $(wc -l < /root/upgrade_code.sh) 行"

echo
echo "=== ② 写 /root/archive_z_out_of_spec.sh ==="
cat > /root/archive_z_out_of_spec.sh <<'EOF'
#!/bin/bash
# archive_z_out_of_spec.sh —— 归档 z 轴（守恒）的**表外尺寸**产物（5×5 / 6×6）。
# 依据：《关卡集总表》守恒轴只收 7×7 / 8×8 / 9×9（扩展层）→ 5×5/6×6 属表外产出。
# 默认 **dry-run**（只统计）；`--apply` 才移动（可逆：文件移到 /root/archive/z_out_of_spec_<日期>/）。
B=/root/.local/share/godot/app_userdata/wm_server
DEST="/root/archive/z_out_of_spec_$(date +%Y%m%d)"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
n=0
for d in "$B"/batch_z*/*; do
  [ -d "$d" ] || continue
  for s in 5x5 6x6; do
    [ -d "$d/$s" ] || continue
    cnt=$(find "$d/$s" -name '*.json' | wc -l)
    echo "  $d/$s : $cnt 关（表外）"
    n=$((n + cnt))
    if [ "$APPLY" = "1" ]; then
      rel="${d#$B/}"
      mkdir -p "$DEST/$(dirname "$rel")"
      mv "$d/$s" "$DEST/$rel/" 2>/dev/null || true
    fi
  done
done
echo "表外 z 产物合计 $n 关"
if [ "$APPLY" = "1" ]; then echo "已归档 → $DEST"; else echo "（dry-run：确认后执行  bash /root/archive_z_out_of_spec.sh --apply）"; fi
EOF
chmod +x /root/archive_z_out_of_spec.sh
echo "已写: $(wc -l < /root/archive_z_out_of_spec.sh) 行"

echo
echo "=== ③ 现状检查 ==="
ls -l /root/mirror_0919.tar.gz
echo "--- z 表外产物统计（dry-run）---"
bash /root/archive_z_out_of_spec.sh 2>&1 | tail -12
