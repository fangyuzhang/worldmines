#!/bin/bash
# 侦察 csproj 文件名字节 + .godot 结构
export HOME=/root
cd /root/minesweeper
echo "=== csproj 候选 ==="
ls -b | grep -i csproj
echo "=== 首字节 ==="
ls | grep -i csproj | head -1 | od -An -tx1 | head -3
echo "=== .godot 结构 ==="
ls .godot/ 2>/dev/null | head -12
echo "=== mono 目录 ==="
ls -la .godot/mono 2>/dev/null
echo "=== project.godot dotnet 段 ==="
grep -A2 "dotnet" project.godot | head -6
echo PROBE_DONE
