#!/bin/bash
echo "=== 链的实际批次调用行（含参数）==="
grep -nE '^\s*(run_batch|wait_godot|nohup|"\$G")' /root/gap_chain.sh | head -40 | cut -c1-210
echo
echo "=== 若上面太短，直接看链全文的 30-90 行 ==="
sed -n '28,95p' /root/gap_chain.sh | cut -c1-200
