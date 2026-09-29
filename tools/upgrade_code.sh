#!/bin/bash
# upgrade_code.sh —— 把服务器代码（core / demo/mods / tools）升级到开发机当前版本。
# 默认 **dry-run**（只报差异）；`--apply` 才真正升级（升级前自动备份到 /root/backup_<stamp>/，
# 升级后跑「口径自检」验证新工具可用）。
# 为什么强调顺序：链在跑时换版会污染产出 —— **只在所有量产进程结束后**执行。
#
# 【09-24 补丁】在「拷码」与「口径自检」之间加了 **--import 类缓存刷新**：
#   新增 class_name 后若不刷缓存，服务器上工具链会全部 "not declared"（09-24 半同步事故的
#   第二个根因：漏推依赖 + 缓存未刷新）。三步缺一不可：文件齐（含依赖）→ --import → 自检。
# 服务器真身在 /root/upgrade_code.sh（备份：/root/upgrade_code.sh.bak_0924）；本文件为仓库留档副本。
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
# 【09-27 补齐】目录清单原先只有 core/demo/tools —— 漏了 **solver/**，
# 于是 C# 走后端的修（含 09-24 的 max_deterministic_time 病态枚举硬上界）从未上线，
# 现网 dll 一直停在 09-15，是挂死/长尾反复复发的直接原因。四目录必须齐全。
for d in core demo/mods tools solver; do
  n=$(diff -rq "$TMP/$d" "$R/$d" 2>/dev/null | grep -c . || true)
  echo "  $d: $n 处差异"
done
echo "--- core 差异明细（前 20）---"
diff -rq "$TMP/core" "$R/core" 2>/dev/null | head -20 || true
echo "--- solver 差异明细 ---"
diff -rq "$TMP/solver" "$R/solver" 2>/dev/null || true

if [ "$APPLY" = "0" ]; then
  echo "（dry-run：确认无误后执行  bash /root/upgrade_code.sh --apply）"
  exit 0
fi

echo "=== 备份 → /root/backup_$STAMP/ ==="
mkdir -p "/root/backup_$STAMP"
cp -a "$R/core" "/root/backup_$STAMP/" 2>/dev/null || true
cp -a "$R/tools" "/root/backup_$STAMP/" 2>/dev/null || true
cp -a "$R/solver" "/root/backup_$STAMP/" 2>/dev/null || true
if [ -d "$R/demo/mods" ]; then
  mkdir -p "/root/backup_$STAMP/demo"
  cp -a "$R/demo/mods" "/root/backup_$STAMP/demo/" 2>/dev/null || true
fi

echo "=== 升级 ==="
cp -a "$TMP/core" "$R/"
cp -a "$TMP/tools" "$R/"
cp -a "$TMP/solver" "$R/"
mkdir -p "$R/demo"
cp -a "$TMP/demo/mods" "$R/demo/"
rm -rf "$TMP"
echo "已升级（回滚：cp -a /root/backup_$STAMP/core /root/backup_$STAMP/tools /root/backup_$STAMP/solver $R/）"

echo "=== C# 重建（solver/ 变了就必须重建，否则 GDScript 用新、C# 用旧 = 半同步）==="
# 原子替换：构建到独立目录后 rename —— 运行中的 Godot 持有旧 inode 不受影响，
# 新起的进程才拿到新 dll（就地覆盖会让已映射旧 dll 的进程读到残缺 IL 而崩溃）。
cd "$R"
export HOME=/root
rm -rf /root/_newbuild
if timeout 900 dotnet build wm_server.csproj -v q -o /root/_newbuild 2>&1 | tail -3; then
  if [ -f /root/_newbuild/wm_server.dll ]; then
    mv -f /root/_newbuild/wm_server.dll "$R/.godot/mono/temp/bin/Debug/wm_server.dll"
    echo "已替换 wm_server.dll（$(stat -c%s "$R/.godot/mono/temp/bin/Debug/wm_server.dll") B）"
  else
    echo "[warn] 构建未产出 dll —— C# 仍是旧版，请人工确认" >&2
  fi
fi
rm -rf /root/_newbuild

echo "=== 类缓存刷新（--import）—— 新增 class_name 后必须刷，防 half-sync（not declared）==="
cd "$R"
"$G" --headless --path . --import > /dev/null 2>&1 || echo "[warn] --import 有报错，自检继续但需人工确认" >&2

echo "=== 口径自检（验证新工具链可用）==="
cd "$R"
"$G" --headless --path . -s tools/batch_all_variants.gd -- user://axis_check 0 1 -2 0 1 2>&1 \
  | sed 's/\x1b\[[0-9;]*m//g' | grep -E "观测轴|结构轴|守恒轴|组合总数|尺寸政策|口径自检" || true
echo "=== 升级完成 ==="
