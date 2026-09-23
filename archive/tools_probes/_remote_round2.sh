#!/bin/bash
# P2 第二轮（o1/o2/o3）：合并分散的历史产物目录 → 等待第一轮完成 → 自动补产。
# 为什么合并：o1/o2/o3 的产物分散在多个历史目录，而产线断点续跑只看 out_dir 一个目录——
#   不合并就会把已有的盘当「没有」而重复生成（浪费机时且产生重复内容）。
# 为什么守护：服务器 2 核已被第一轮（双路 o10/o5x/o4 ‖ o8/o9）占满，第二轮必须排队。
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server

# ---- 1) 合并（Python：按 (子目录, 档位) 顺序重编号，满足 _scan_unit 的 <tier>_<int> 解析）----
cat > /root/merge_units.py <<'PYEOF'
import collections, os, shutil, sys

B = "/root/.local/share/godot/app_userdata/wm_server"
TIERS = ("intro", "easy", "normal", "hard")


def merge(dst, srcs):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    cnt = collections.Counter()
    for src in srcs:
        base = os.path.join(B, src)
        if not os.path.isdir(base):
            continue
        for root, _, files in os.walk(base):
            for f in sorted(files):
                if not f.endswith(".json") or "report" in f:
                    continue
                tier = f.split("_")[0]
                if tier not in TIERS:
                    continue
                rel = os.path.relpath(root, base)
                cnt[(rel, tier)] += 1
                td = os.path.join(dst, rel)
                os.makedirs(td, exist_ok=True)
                shutil.copy2(os.path.join(root, f),
                             os.path.join(td, "%s_%02d.json" % (tier, cnt[(rel, tier)])))
    return sum(cnt.values())


JOBS = [
    ("batch_o1_merged", ["batch_o1_7", "batch_o1_8", "batch_o1_9", "batch_o1b_7", "batch_o1b_8", "batch_o1c"]),
    ("batch_o2_merged", ["batch_o2_57", "batch_o2_8"]),
    ("batch_o3_merged", ["batch_o3", "batch_o3b"]),
]
for name, srcs in JOBS:
    n = merge(os.path.join(B, name), srcs)
    print("merged %s: %d 关" % (name, n))
    d = os.path.join(B, name)
    for combo in sorted(os.listdir(d)):
        cdir = os.path.join(d, combo)
        if not os.path.isdir(cdir):
            continue
        for side in sorted(os.listdir(cdir)):
            sdir = os.path.join(cdir, side)
            if not os.path.isdir(sdir):
                continue
            parts = []
            total = 0
            for t in TIERS:
                c = len([x for x in os.listdir(sdir) if x.startswith(t + "_")])
                total += c
                if c:
                    parts.append("%s=%d" % (t, c))
            print("    %s/%s: %d  [%s]" % (combo, side, total, " ".join(parts)))
print("MERGE_PY_DONE")
PYEOF

python3 /root/merge_units.py 2>&1

# ---- 2) 守护 + 第二轮补产（等第一轮全部进程退出）----
G=/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64
rm -f /root/gen_gap_C.log
setsid nohup bash -c "
while pgrep -f 'batch_all_variants' > /dev/null; do sleep 300; done
echo '第一轮已结束，启动第二轮' \$(date)
cd /root/minesweeper
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o1_merged 10 1200 -1 1 1 410 0 o1@5-9 o1_duichuan 100 3000 tiered 30
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o2_merged 10 1200 -1 1 1 410 0 o2@5-9 o2_linxu 100 3000 tiered 30
$G --headless --path . -s res://tools/batch_all_variants.gd -- user://batch_o3_merged 10 1200 -1 1 1 410 0 o3@5-9 o3_fendang 100 3000 tiered 30
echo ROAD_C_DONE
" >> /root/gen_gap_C.log 2>&1 &

sleep 3
echo '=== 守护进程已挂 ==='
ps -ef | grep -c "[b]atch_all_variants"
echo '=== 当前第一轮状态（应仍在跑）==='
pgrep -af batch_all_variants | head -3 | cut -c1-120
echo ROUND2_SETUP_DONE
