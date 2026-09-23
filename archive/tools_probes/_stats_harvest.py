# -*- coding: utf-8 -*-
# _stats_harvest.py —— 收割产物统计（尺寸×档矩阵 + 难度分布 + issues 事件计数）
import json
import glob
import os
import collections
import sys

sys.stdout.reconfigure(encoding="utf-8")

BASE = r"_staged_levels\harvest_0915"
DIRS = ["batch_o2_57", "batch_o2_8", "batch_o3", "batch_o5x", "batch_o1_9", "batch_o1b_7", "batch_o1b_8"]

total_all = 0
for d in DIRS:
    dpath = os.path.join(BASE, d)
    if not os.path.isdir(dpath):
        print(f"=== {d} === (缺)")
        continue
    cnt = collections.Counter()
    diffs = []
    fails = 0
    for f in glob.glob(os.path.join(dpath, "**", "*.json"), recursive=True):
        try:
            with open(f, encoding="utf-8") as fh:
                j = json.load(fh)
            size = j.get("size", {})
            size_s = "%sx%s" % (size.get("cols", "?"), size.get("rows", "?"))
            tier = os.path.basename(f).split("_")[0]
            rel = os.path.relpath(f, dpath)
            combo = rel.split(os.sep)[0] if os.sep in rel else "(top)"
            cnt[(combo, size_s, tier)] += 1
            dp = j.get("difficulty_profile", {})
            if "difficulty" in dp:
                diffs.append(float(dp["difficulty"]))
        except Exception:
            fails += 1
    n = sum(cnt.values())
    total_all += n
    print(f"=== {d} === 关数={n} 解析失败={fails}")
    # 聚合为「组合_尺寸 → 档位计数」
    unit2 = {}
    for (combo, size_s, tier), v in cnt.items():
        unit2.setdefault((combo, size_s), collections.Counter())[tier] = v
    for key in sorted(unit2):
        c = unit2[key]
        dist = " ".join(f"{t}={c[t]}" for t in ("intro", "easy", "normal", "hard") if c[t] > 0)
        print(f"   {key[0]:<16} {key[1]:>5} | {dist}")
    if diffs:
        print(f"   difficulty: min={min(diffs):.2f} max={max(diffs):.2f} avg={sum(diffs)/len(diffs):.2f}")
    # issues 事件计数
    ipath = os.path.join(dpath, "issues.jsonl")
    if os.path.isfile(ipath):
        ev = collections.Counter()
        with open(ipath, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev[json.loads(line).get("t", "?")] += 1
                except Exception:
                    pass
        top = ", ".join(f"{k}={v}" for k, v in ev.most_common(8))
        print(f"   issues: {top}")

print(f"\nTOTAL(new harvest) = {total_all}")
