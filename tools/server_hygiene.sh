#!/bin/bash
# 服务器卫生（2026-09-23）：
#   ① wasm 修复后复验 mod_api.gd 能否编译（根因：wasm_sandbox.gd 写死 Wasm 类型，服务器无该插件）
#   ② 加 2GB swap（机器 1.9GB 内存 + 双 Godot 并行 → OOM 杀进程）
#   ③ 排队「薄集补齐」：等 fill_chain.sh 退出后，用项目自带 fill_level_lib.sh 单分片跑
cd /root/minesweeper || exit 1
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64

echo "=== ① mod_api.gd 编译复验 ==="
timeout 180 "$G" --headless --path . --check-only --script res://core/mod_api.gd 2>&1 \
  | grep -viE '^$|Godot Engine|godot_ai|mcp capture|root.*superuser|GODOT_SILENCE|at: setup2' | head -8
echo "（无 SCRIPT ERROR / Failed to load 即通过）"

echo "=== ② swap ==="
free -m | head -3
swapon --show 2>/dev/null || echo "（无 swap）"
df -h / | tail -1
if swapon --show 2>/dev/null | grep -q .; then
  echo "已有 swap，跳过创建"
elif [ "$(df -m / | tail -1 | awk '{print $4}')" -lt 3072 ]; then
  echo "⚠️ 磁盘可用不足 3GB，跳过 swap 创建"
else
  echo "创建 2GB swap..."
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile && mkswap /swapfile > /dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "swap 已启用：$(swapon --show | tail -1)"
fi
free -m | head -2
echo "vm.swappiness=$(cat /proc/sys/vm/swappiness)"

echo "=== ③ 排队薄集补齐（等当前链退出）==="
cat > /root/thin_fill_queue.sh <<'EOS'
#!/bin/bash
# 等 fill_chain.sh 退出 → 单分片跑 fill_level_lib.sh（-t 20：22 席全覆盖优先，满额单元自动跳过）
cd /root/minesweeper || exit 1
log=/root/thin_fill.log
echo "=== 排队开始 $(date '+%F %H:%M:%S')，等待 fill_chain.sh 退出 ===" >> "$log"
while pgrep -f "fill_chain.sh" > /dev/null; do sleep 120; done
echo "=== 链已退出，开始薄集补齐 $(date '+%F %H:%M:%S') ===" >> "$log"
GODOT=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64 \
  bash tools/fill_level_lib.sh -t 20 -s 1 >> "$log" 2>&1
echo "=== 薄集补齐结束 $(date '+%F %H:%M:%S') ===" >> "$log"
EOS
chmod +x /root/thin_fill_queue.sh
if pgrep -f "thin_fill_queue.sh" > /dev/null; then
  echo "薄集补齐已在排队（不重复启动）"
else
  nohup bash /root/thin_fill_queue.sh > /dev/null 2>&1 &
  sleep 3
  echo "已排队: $(pgrep -af 'thin_fill_queue.sh' | head -1)"
fi
echo HYGIENE_DONE
