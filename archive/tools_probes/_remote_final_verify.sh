#!/bin/bash
# 服务器：跑后总验收（一键，全输出写 /root/final_verify.log，后台跑）
# [1] verify_batch v3（R07/schema/round-trip/序贯可解）
# [2] diversity_report（全局多样性：J 分布/峰值对/同质化组）
# [3] 日志错误扫描（SCRIPT ERROR/ERROR 分类）
# [4] 产物打包
export HOME=/root
export GODOT_SILENCE_ROOT_WARNING=1
GD=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
B=/root/.local/share/godot/app_userdata/wm_server/batch_all
cd /root/minesweeper
{
  echo "########## [1/4] verify_batch v3 ##########"
  "$GD" --headless --path . -s res://tools/verify_batch.gd -- user://batch_all
  echo "########## [2/4] diversity_report ##########"
  "$GD" --headless --path . -s res://tools/diversity_report.gd -- user://batch_all
  echo "########## [3/4] error scan ##########"
  bash /root/scan_errors.sh 2>/dev/null
  echo "########## [4/4] collect ##########"
  tar -czf /root/wm_results.tar.gz -C "$B" . 2>/dev/null
  ls -la /root/wm_results.tar.gz
  echo "FINAL_VERIFY_DONE $(date '+%F %T')"
} > /root/final_verify.log 2>&1
tail -40 /root/final_verify.log
