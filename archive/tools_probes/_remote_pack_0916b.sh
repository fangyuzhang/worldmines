export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server
cd "$B"
rm -f /root/harvest_0916b.tar.gz
tar czf /root/harvest_0916b.tar.gz batch_o1_9 batch_o1b_7 batch_o1b_8 batch_o1c batch_o2_57 batch_o2_8 batch_o3 batch_o3b 2>/dev/null
stat -c %s /root/harvest_0916b.tar.gz
echo TAR_DONE
