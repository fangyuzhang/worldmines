#!/bin/bash
# 收割 3：o8（钟点；任务已正常完成 26997.9s，710 关入库）
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server
cd /root
rm -f /root/wm_harvest_o8.tar.gz
tar -czf /root/wm_harvest_o8.tar.gz -C "$B" batch_o8
echo '=== size ==='
ls -la /root/wm_harvest_o8.tar.gz
echo '=== md5 ==='
md5sum /root/wm_harvest_o8.tar.gz
echo '=== count ==='
find "$B/batch_o8" -name '*.json' | wc -l
echo HARVEST_O8_DONE
