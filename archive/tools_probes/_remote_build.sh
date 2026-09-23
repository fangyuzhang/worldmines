#!/bin/bash
# 服务器：首次导入 + dotnet build（大任务，后台跑）
export HOME=/root
GD=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
cd /root/minesweeper
{
  echo "=== [1/2] godot --import ==="
  "$GD" --headless --path . --import
  echo "IMPORT_EXIT=$?"
  echo "=== [2/2] dotnet build ==="
  dotnet build "世界扫雷 (Copy).csproj" -v minimal
  echo "BUILD_EXIT=$?"
  echo "=== 产物 ==="
  ls -la bin/Debug/net9.0/ 2>/dev/null | head -10
  ls -la .godot/mono/temp/bin/Debug/ 2>/dev/null | head -10
  echo ALL_DONE
} > /root/smoke.log 2>&1
tail -45 /root/smoke.log
