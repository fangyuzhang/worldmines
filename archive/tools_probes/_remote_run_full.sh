#!/bin/bash
# 服务器：全量生成启动（2 核 → 2 分片；nohup 保活；issues 记录随产）
# 用法：bash _remote_run_full.sh [per_type] [seed_max]
export HOME=/root
PER=${1:-10}
SEED=${2:-40}
GD=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64

# 2G 内存保险：加 2G swap（首次运行）
if [ ! -f /swapfile2g ]; then
  dd if=/dev/zero of=/swapfile2g bs=1M count=2048 status=none
  chmod 600 /swapfile2g
  mkswap /swapfile2g > /dev/null
  swapon /swapfile2g
fi

cd /root/minesweeper
for i in 0 1; do
  nohup "$GD" --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_all "$PER" "$SEED" 0 "$i" 2 > "/root/gen_shard_$i.log" 2>&1 &
  echo "started shard $i pid=$!"
done
sleep 20
echo "=== 进程检查 ==="
ps aux | grep -c "[G]odot_v4.7.2"
echo "=== 20s 后日志尾部 ==="
tail -3 /root/gen_shard_0.log
echo RUN_LAUNCHED
