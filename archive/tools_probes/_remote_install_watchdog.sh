#!/bin/bash
# 服务器：停旧 watchdog → 注册 systemd 自愈服务（服务器重启后自动拉起）
pkill -f 'bash /root/watchdog.sh' 2>/dev/null || true
sleep 1
cat > /etc/systemd/system/wm-gen-watchdog.service <<'EOF'
[Unit]
Description=WM Generator Watchdog
After=network.target

[Service]
ExecStart=/bin/bash /root/watchdog.sh
Restart=on-failure
RestartSec=30
KillMode=process
WorkingDirectory=/root/minesweeper

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now wm-gen-watchdog
sleep 3
echo "=== 服务状态 ==="
systemctl is-active wm-gen-watchdog
systemctl status wm-gen-watchdog --no-pager 2>&1 | head -8
echo "=== watchdog 进程 ==="
pgrep -af 'watchdog.sh' | head -3
echo "=== 生成进程数（应=2）==="
pgrep -fc batch_all_variants
echo SYSTEMD_OK
