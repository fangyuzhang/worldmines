B=/root/.local/share/godot/app_userdata/wm_server
n=$(find $B/batch_o4 -name '*.json' | grep -v report | wc -l)
echo "batch_o4: $n 关（仍在生成）"
tail -1 /root/gen_chain_main.log
echo O4_CHECK_DONE
