# -*- coding: utf-8 -*-
# M05 验收口径：按「集 = 包/机制/尺寸」统计各档关数（hard 集是否欠产）
import json
import glob
import os

BASE = r"C:\Users\zjh30\CodeBuddy\20260906184916\_staged_levels"
PACKS = ["batch_all_v293_20260913", "harvest_0915", "harvest_0915b",
         "harvest_o8", "o1_batch_20260914"]
TIDS = ["intro", "easy", "normal", "hard"]


def tier_of(d):
    if d < 0.3:
        return "intro"
    if d < 1.2:
        return "easy"
    if d < 2.2:
        return "normal"
    return "hard"


sets = {}
for pkg in PACKS:
    root = os.path.join(BASE, pkg)
    if not os.path.isdir(root):
        continue
    for f in glob.glob(os.path.join(root, "**", "*.json"), recursive=True):
        b = os.path.basename(f)
        if b.startswith("all_report") or b.endswith("issues.json"):
            continue
        rel = os.path.relpath(f, root).replace("\\", "/")
        key = pkg + "/" + os.path.dirname(rel)
        try:
            j = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        d = float(j.get("difficulty_profile", {}).get("difficulty", -1.0))
        if d < 0:
            continue
        sets.setdefault(key, {t: 0 for t in TIDS})[tier_of(d)] += 1

items = [(k, v) for k, v in sets.items()]
n_sets = len(items)
b60 = [k for k, v in items if v["hard"] >= 60]
b30 = [k for k, v in items if 30 <= v["hard"] < 60]
b1 = [k for k, v in items if 1 <= v["hard"] < 30]
b0 = [k for k, v in items if v["hard"] == 0]

print("=== 按集统计（集 = 包/机制/尺寸；共 %d 集）===" % n_sets)
print("  hard >= 60 关（达标）: %d 集 (%.0f%%)" % (len(b60), 100.0 * len(b60) / max(1, n_sets)))
print("  hard 30-59 关（欠产）: %d 集 (%.0f%%)" % (len(b30), 100.0 * len(b30) / max(1, n_sets)))
print("  hard 1-29 关（严重欠产）: %d 集 (%.0f%%)" % (len(b1), 100.0 * len(b1) / max(1, n_sets)))
print("  hard 0 关（空集）: %d 集 (%.0f%%)" % (len(b0), 100.0 * len(b0) / max(1, n_sets)))

# 只看「结构型/主力算子」的集（有尺寸层，且总关数 >= 100 的成熟集）
print()
print("=== hard 最足的集（top 15）===")
for k, v in sorted(items, key=lambda x: -x[1]["hard"])[:15]:
    tot = sum(v.values())
    print("  %-46s n=%-4d hard=%-4d (%.0f%%)" % (k, tot, v["hard"], 100.0 * v["hard"] / max(1, tot)))

print()
print("=== 成熟集（总关数 >= 100）的 hard 分布 ===")
mature = [(k, v) for k, v in items if sum(v.values()) >= 100]
print("  成熟集数: %d" % len(mature))
if mature:
    hs = sorted(v["hard"] for _, v in mature)
    print("  hard 关数 中位数=%d 最小=%d 最大=%d" % (hs[len(hs) // 2], hs[0], hs[-1]))
    print("  其中 hard >= 60 的: %d 集 (%.0f%%)" % (
        sum(1 for _, v in mature if v["hard"] >= 60),
        100.0 * sum(1 for _, v in mature if v["hard"] >= 60) / len(mature)))
    print("  其中 hard == 0 的: %d 集" % sum(1 for _, v in mature if v["hard"] == 0))
