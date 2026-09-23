#!/bin/bash
# 服务器：全量生成启动（2 核 → 2 分片）
# 标准全量：92 组合 × 5 尺寸 × 每类 10 关（自动跳 UNSAT/design_skip；issues 记录随产）
export HOME=/root
export GODOT_SILENCE_ROOT_WARNING=1
cd /root/minesweeper
GD=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64

# 0) 确认超时系数已更新
grep -m1 "side \* side \* " tools/batch_all_variants.gd

# 1) ASCII 项目名（user:// → app_userdata/wm_server/，路径干净）
sed -i 's|^config/name=.*|config/name="wm_server"|' project.godot
grep '^config/name' project.godot

# 2) 2G swap 保险
if [ ! -f /swapfile2g ]; then
  dd if=/dev/zero of=/swapfile2g bs=1M count=2048 status=none
  chmod 600 /swapfile2g
  mkswap /swapfile2g > /dev/null && swapon /swapfile2g
fi
echo "=== 内存 ==="
free -m | head -3

# 3) 启动 2 分片（nohup 脱离会话，TAT 命令结束后继续跑）
for i in 0 1; do
  nohup "$GD" --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_all 10 40 0 "$i" 2 > "/root/gen_shard_$i.log" 2>&1 &
  echo "shard $i pid=$!"
done
sleep 45
echo "=== 存活进程数（应=2）==="
pgrep -fc "batch_all_variants" || echo 0
echo "=== shard_0 日志尾部 ==="
tail -4 /root/gen_shard_0.log
echo "=== shard_1 日志尾部 ==="
tail -4 /root/gen_shard_1.log
echo LAUNCHED
