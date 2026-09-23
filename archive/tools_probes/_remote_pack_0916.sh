export HOME=/root
cd /root/.local/share/godot/app_userdata/wm_server
rm -f /root/harvest_0916.tar.gz
tar czf /root/harvest_0916.tar.gz batch_o9 batch_o10 2>/dev/null
stat -c %s /root/harvest_0916.tar.gz
echo TAR_DONE
