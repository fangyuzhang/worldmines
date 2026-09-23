#!/bin/bash
# 服务器：下载并解包 Godot 4.7.2 mono Linux（ghfast.top 代理，GitHub 直连资产不可达）
set -e
mkdir -p /opt/godot
cd /opt/godot
if [ ! -f godot.zip ] || [ "$(stat -c%s godot.zip 2>/dev/null || echo 0)" -lt 100000000 ]; then
  curl -sL -o godot.zip.part 'https://ghfast.top/https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_mono_linux_x86_64.zip'
  mv godot.zip.part godot.zip
fi
echo "DL_OK $(stat -c%s godot.zip)"
unzip -q -o godot.zip
echo "=== /opt/godot 内容 ==="
ls -la
echo UNZIP_OK
