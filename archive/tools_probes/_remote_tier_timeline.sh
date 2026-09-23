export HOME=/root
f=/root/.local/share/godot/app_userdata/wm_server/batch_o5x/issues.jsonl
echo '=== tier_empty 时间线：文件首末 mtime + 事件里有没有时间字段 ==='
ls -la --time-style='+%m-%d %H:%M' $f
echo '--- 前 3 行 ---'
head -3 $f | cut -c1-150
echo '--- 后 3 行 ---'
tail -3 $f | cut -c1-150
echo '=== difficulty.gd 服务器版 intro 判定（关键 4 行）==='
sed -n '15,20p' /root/minesweeper/core/difficulty.gd
echo TIER_TL_DONE
