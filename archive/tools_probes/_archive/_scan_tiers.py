# -*- coding: utf-8 -*-
# 全量产物四档分布扫描（M05「hard 档稀少」对策支撑）
# 实档 = difficulty_profile.difficulty 按 difficulty.gd 阈值分档（不看文件名）
# 同时质检：文件名前缀档 vs 实档 一致性
import json
import glob
import os
import statistics

BASE = r"C:\Users\zjh30\CodeBuddy\20260906184916\_staged_levels"
PACKS = ["batch_all_v293_20260913", "harvest_0915", "harvest_0915b",
         "harvest_o8", "o1_batch_20260914"]
TIDS = ["intro", "easy", "normal", "hard"]
TLAB = {"intro": "入门", "easy": "普通", "normal": "困难", "hard": "噩梦"}


def tier_of(d):
    if d < 0.3:
        return "intro"
    if d < 1.2:
        return "easy"
    if d < 2.2:
        return "normal"
    return "hard"


def fname_tier(f):
    b = os.path.basename(f)
    for t in TIDS:
        if b.startswith(t + "_"):
            return t
    return ""


rows = {}
total = {t: 0 for t in TIDS}
total_n = 0
mismatch = []
missing_diff = 0

for pkg in PACKS:
    root = os.path.join(BASE, pkg)
    if not os.path.isdir(root):
        continue
    for f in glob.glob(os.path.join(root, "**", "*.json"), recursive=True):
        b = os.path.basename(f)
        if b.startswith("all_report") or b.endswith("issues.json"):
            continue
        rel = os.path.relpath(f, root).replace("\\", "/")
        parts = rel.split("/")
        key = pkg + "/" + (parts[0] if len(parts) > 1 else "(root)")
        try:
            j = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        dp = j.get("difficulty_profile", {})
        if "difficulty" not in dp:
            missing_diff += 1
            continue
        d = float(dp["difficulty"])
        t = tier_of(d)
        rows.setdefault(key, []).append((t, d, fname_tier(f)))
        total[t] += 1
        total_n += 1
        ft = fname_tier(f)
        if ft and ft != t:
            mismatch.append((rel, ft, t, round(d, 2)))

print("=== 按包/批次（实档计数）===")
for key in sorted(rows):
    items = rows[key]
    c = {t: 0 for t in TIDS}
    for t, d, ft in items:
        c[t] += 1
    ds = [d for _, d, _ in items]
    n = len(items)
    print("%-34s n=%-5d 入门=%-5d 普通=%-5d 困难=%-5d 噩梦=%-5d | min=%.2f max=%.2f avg=%.2f" % (
        key, n, c["intro"], c["easy"], c["normal"], c["hard"],
        min(ds), max(ds), statistics.mean(ds)))

print()
print("=== 全量汇总（%d 关）===" % total_n)
for t in TIDS:
    pct = 100.0 * total[t] / total_n if total_n else 0.0
    print("  %s(%s): %d  (%.1f%%)" % (TLAB[t], t, total[t], pct))

print()
print("=== 档位目标对比（M05：噩梦占 1/3）===")
if total_n:
    print("  噩梦实际占比 %.1f%%  vs 目标 33.3%%  → 缺口 %.0f 关" % (
        100.0 * total["hard"] / total_n,
        max(0.0, total_n / 3.0 - total["hard"])))

print()
print("=== 质检 ===")
print("  无 difficulty_profile 的 json: %d" % missing_diff)
print("  文件名档 != 实档: %d 例" % len(mismatch))
for rel, ft, t, d in mismatch[:12]:
    print("    %s  文件名=%s 实档=%s (d=%.2f)" % (rel, ft, t, d))
