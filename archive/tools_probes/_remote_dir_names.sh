#!/bin/bash
# 服务器各批次的「组合目录名」实况（导入闸门的判定输入）
B=/root/.local/share/godot/app_userdata/wm_server
echo "=== 各批次的组合目录名（去重）==="
for d in batch_o10 batch_o1_merged batch_o2_merged batch_o3_merged batch_o4 batch_o5x batch_o8 batch_o9 batch_s1 batch_s2 batch_s3 batch_s4 batch_z1 batch_z4; do
  [ -d "$B/$d" ] || continue
  names=$(ls "$B/$d" 2>/dev/null | head -3 | tr '\n' ' ')
  echo "  $d → $names"
done
echo
echo "=== 本地新版工具会怎么命名（离线推演用不上，这里看服务器版工具的命名代码）==="
grep -n '"x_\|x_%s\|_dir_name\|combo_dir :=' /root/minesweeper/tools/batch_all_variants.gd | head -8
