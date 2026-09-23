#!/bin/bash
# 把排队中的「uniform 薄集补齐」换成「curated 计划」：
#   · 旧方案 fill_level_lib.sh -t 20 会连结构性不可达单元一起烧（o8/o9/dt 的 hard、shape_*），
#     按 200 seeds × ~18s ≈ 每格 1 小时估，约 40 格 = 20–40h 纯浪费；
#   · 新方案由 tools/thin_cells.py --emit-plan 生成：只补可补单元，官方窗口启动器串行跑，含等空闲核守卫。
echo "=== 停掉旧排队（uniform）==="
pkill -f "thin_fill_queue.sh" && echo "已停 thin_fill_queue.sh" || echo "（旧排队不在运行）"
sleep 1
pgrep -af "thin_fill_queue" | head -3

echo "=== 部署计划脚本 ==="
ls -la /root/thin_fill_plan.sh 2>/dev/null || { echo "计划脚本未推送"; exit 1; }
echo "补产命令数: $(grep -c 'run_window_production.sh' /root/thin_fill_plan.sh)"

echo "=== 启动（等空闲核 → 逐轮跑）==="
if pgrep -f "thin_fill_plan.sh" > /dev/null; then
  echo "计划已在运行（不重复启动）"
else
  nohup bash /root/thin_fill_plan.sh > /dev/null 2>&1 &
  sleep 3
  echo "已启动: $(pgrep -af 'thin_fill_plan.sh' | head -1)"
fi

echo "=== 当前状态（计划会等空闲核，不与现有链抢）==="
ps -eo pid,etime,pcpu,comm | grep -i godot | head -4
echo "计划日志: /root/thin_fill_plan.log ｜ 各轮日志: /root/gen_window_<tag>.log"
echo SWAP_QUEUE_DONE
