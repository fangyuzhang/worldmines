#!/bin/bash
# 服务器：修复中文文件名编码损坏（tar 打包链路的码页问题）→ ASCII 名 + 同步 assembly_name → 构建
export HOME=/root
cd /root/minesweeper
GD=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64

# 1) csproj 改名（ASCII）——原中文名的 UTF-8 字节被解包环节按 GBK 双重编码损坏
if [ ! -f wm_server.csproj ]; then
  old=$(ls *.csproj | head -1)
  echo "old name bytes: $(echo "$old" | od -An -tx1 | head -1)"
  mv "$old" wm_server.csproj
fi
echo "csproj: $(ls *.csproj)"

# 2) assembly_name 同步（Godot.NET.Sdk 默认 AssemblyName = csproj 文件名 = wm_server）
sed -i 's|^project/assembly_name=.*|project/assembly_name="wm_server"|' project.godot
grep -A1 "dotnet" project.godot | head -4

# 3) 重新导入（.godot 缓存与改名后的项目对齐）
"$GD" --headless --path . --import > /root/reimport.log 2>&1
echo "REIMPORT_EXIT=$?"

# 4) 构建（首次会拉 Godot.NET.Sdk + Google.OrTools 的 NuGet 包）
dotnet build wm_server.csproj -v minimal > /root/build.log 2>&1
echo "BUILD_EXIT=$?"
tail -15 /root/build.log
echo "=== bin 产物 ==="
ls bin/Debug/net9.0/ 2>/dev/null | head -15
echo FIX_DONE
