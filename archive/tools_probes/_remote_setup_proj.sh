#!/bin/bash
# 服务器：解包项目到 /root/minesweeper
set -e
cd /root
rm -rf minesweeper
mkdir -p minesweeper
tar -xzf wm_server.tar.gz -C minesweeper
cd minesweeper
echo "=== 根目录 ==="
ls
echo "=== core 文件数: $(ls core | wc -l) ==="
echo "=== csproj: $(ls *.csproj) ==="
echo "=== solver: $(ls solver) ==="
echo SETUP_OK
