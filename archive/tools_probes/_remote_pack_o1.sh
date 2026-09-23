#!/bin/bash
# O1 产物打包（7×7 / 8×8 / 9×9 试产 + issues）
export HOME=/root
cd /root/.local/share/godot/app_userdata/wm_server
tar czf /root/o1_results.tar.gz batch_o1_7 batch_o1_8 batch_o1_9 2>/dev/null
echo '=== tarball ==='
ls -la /root/o1_results.tar.gz
md5sum /root/o1_results.tar.gz
echo '=== per-dir counts ==='
for d in batch_o1_7 batch_o1_8 batch_o1_9; do
  printf '%s json: ' "$d"
  find $d -name '*.json' 2>/dev/null | wc -l
  printf '%s issues lines: ' "$d"
  wc -l < $d/issues.jsonl 2>/dev/null || echo 0
done
echo PACK_O1_DONE
