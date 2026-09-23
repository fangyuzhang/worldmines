#!/bin/bash
# 交接状态快照（关机前记录）
B=/root/.local/share/godot/app_userdata/wm_server
date '+%F %H:%M:%S'
echo "--- 量产进程 ---"
ps -eo pid,etime,comm= | grep Godot | cut -c1-46
echo "--- 链/补批守护 ---"
pgrep -af 'gap_chain' | head -3
echo "--- 链日志尾 ---"
tail -2 /root/gen_chain_main.log
tail -1 /root/gen_chain2.log 2>/dev/null || echo "(gap_chain2 日志尚无内容：仍在等主链结束)"
echo "--- 关键批次关数 ---"
for d in s1 s2 s3 s4 s6 z1 z4; do
  n=$(find "$B/batch_$d" -name '*.json' 2>/dev/null | grep -v report | wc -l)
  echo "  batch_$d: $n 关"
done
echo "--- 服务器总产出 ---"
find "$B"/batch_* -name '*.json' 2>/dev/null | grep -v report | wc -l
echo "--- 归档区 ---"
ls -d /root/archive/* 2>/dev/null
echo "--- 待执行（链跑完后）---"
echo "  bash /root/upgrade_code.sh --apply            # 代码升级到开发机版本"
echo "  bash /root/archive_z_out_of_spec.sh --apply   # z2/z3/z5 表外尺寸归档"
echo "  然后：收割（一致性检查→拉回→隐藏态回填→门禁→导入）见 交接文档.md"
