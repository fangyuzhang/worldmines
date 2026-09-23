#!/bin/bash
# 服务器：验证 Godot mono 可执行
export HOME=/root
GD_DIR=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64
echo "=== 目录结构 ==="
ls -la "$GD_DIR"
echo "=== GodotSharp ==="
ls "$GD_DIR/GodotSharp" | head -8
GD="$GD_DIR/Godot_v4.7.2-stable_mono_linux.x86_64"
chmod +x "$GD" 2>/dev/null
echo "=== 版本 ==="
"$GD" --version 2>&1 | head -3
echo "=== dotnet 环境 ==="
dotnet --list-runtimes 2>&1 | grep -i "NETCore.App 9" | head -2
echo VERIFY_DONE
