#!/bin/bash
# 看 final_verify.log 的错误计数与表头
export HOME=/root
echo "=== SCRIPT ERROR 计数 ==="
grep -c "SCRIPT ERROR" /root/final_verify.log 2>/dev/null || echo 0
echo "=== 最常出现的错误（去重前 5）==="
grep -A1 "SCRIPT ERROR" /root/final_verify.log 2>/dev/null | grep -v "^--" | sort | uniq -c | sort -rn | head -6
echo "=== log 表头 ==="
head -12 /root/final_verify.log
echo "=== 当前尾部 ==="
tail -6 /root/final_verify.log
echo PEEK_DONE
