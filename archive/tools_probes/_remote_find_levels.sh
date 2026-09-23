#!/bin/bash
echo "=== /root 一级目录 ==="
ls -la /root/ | head -20
echo "=== minesweeper 目录 ==="
ls -la /root/minesweeper/ 2>/dev/null | head -30
echo "=== 链脚本里的输出参数 ==="
sed -n '1,40p' /root/gap_chain.sh 2>/dev/null || echo "(无 /root/gap_chain.sh)"
echo "=== JSON 文件分布（前 15 个目录，按数量）==="
find /root -maxdepth 4 -name "*.json" -not -name "*report*" 2>/dev/null | sed 's|/[^/]*$||' | sort | uniq -c | sort -rn | head -15
echo "=== 总 JSON 数 ==="
find /root -maxdepth 4 -name "*.json" -not -name "*report*" 2>/dev/null | wc -l
