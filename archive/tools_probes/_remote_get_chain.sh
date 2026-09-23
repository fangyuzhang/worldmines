#!/bin/bash
# 取生产链脚本里的权威 mod 映射（每个批次用的 mod 名与规格）
echo "=== /root/gap_chain.sh（权威映射）==="
if [ -f /root/gap_chain.sh ]; then
  grep -v '^\s*#' /root/gap_chain.sh | grep -v '^\s*$' | head -40
else
  ls /root/*.sh
fi
echo "=== 服务器 mods 目录 ==="
ls /root/minesweeper/demo/mods 2>/dev/null | head -40
echo CHAIN_INFO_DONE
