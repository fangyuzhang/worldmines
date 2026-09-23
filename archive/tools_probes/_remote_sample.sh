#!/bin/bash
# 服务器：分层随机抽样（每尺寸 6 关，共 30 关，保留目录结构以便溯源）
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server/batch_all
OUT=/root/sample_eval
rm -rf $OUT && mkdir -p $OUT
for side in 5 6 7 8 9; do
  find $B -path "*${side}x${side}*" -name "*.json" ! -name "all_report*" ! -name "issues*" | shuf -n 6 | while read f; do
    rel=${f#$B/}
    mkdir -p "$OUT/$(dirname "$rel")"
    cp "$f" "$OUT/$rel"
  done
done
echo "=== 抽样关数 ==="
find $OUT -name "*.json" | wc -l
echo "=== 样本清单 ==="
find $OUT -name "*.json" | sed "s|$OUT/||" | sort
tar -czf /root/sample_eval.tar.gz -C $OUT .
ls -la /root/sample_eval.tar.gz
echo SAMPLE_DONE
