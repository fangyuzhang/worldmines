export HOME=/root
cd /root/.local/share/godot/app_userdata/wm_server
rm -f /root/harvest_0915.tar.gz
tar czf /root/harvest_0915.tar.gz batch_o2_57 batch_o2_8 batch_o3 batch_o5x batch_o1_9 batch_o1b_7 batch_o1b_8 2>/dev/null
stat -c %s /root/harvest_0915.tar.gz
echo TAR_DONE
