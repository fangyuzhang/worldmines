# -*- coding: utf-8 -*-
"""收割产物分析（通用版，2026-09-16）：关数 / 难度分布 / 四档分布 / 尺寸分布 / issues 事件。
用法：python tools/_analyze_harvest.py <harvest_dir>
"""
import collections
import glob
import json
import os
import statistics
import sys

HARVEST = sys.argv[1] if len(sys.argv) > 1 else \
    r"C:\Users\zjh30\CodeBuddy\20260906184916\_staged_levels\harvest_0916"

TIERS = [("intro", 0.0, 0.3), ("easy", 0.3, 1.2), ("normal", 1.2, 2.2), ("hard", 2.2, 1e9)]


def tier_of(d):
    for name, lo, hi in TIERS:
        if lo <= d < hi:
            return name
    return "?"


for d in sorted(os.listdir(HARVEST)):
    base = os.path.join(HARVEST, d)
    if not os.path.isdir(base):
        continue
    ds = []
    tiers = collections.Counter()
    sizes = collections.Counter()
    for f in glob.glob(base + r"\**\*.json", recursive=True):
        if "all_report" in f:
            continue
        try:
            j = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        diff = float(j.get("difficulty_profile", {}).get("difficulty", 0.0))
        ds.append(diff)
        tiers[tier_of(diff)] += 1
        sz = j.get("size", {})
        sizes["%sx%s" % (sz.get("cols"), sz.get("rows"))] += 1
    if not ds:
        print("%s: 无关卡" % d)
        continue
    print("=== %s ===" % d)
    print("  关数=%d  难度 min=%.2f max=%.2f avg=%.2f med=%.2f" % (
        len(ds), min(ds), max(ds), statistics.mean(ds), statistics.median(ds)))
    print("  四档: " + " / ".join("%s=%d" % (k, tiers[k]) for k in ["intro", "easy", "normal", "hard"]))
    print("  尺寸: " + " / ".join("%s=%d" % (k, v) for k, v in sorted(sizes.items())))
    iss = os.path.join(base, "issues.jsonl")
    if os.path.exists(iss):
        ev = collections.Counter()
        units = []
        for line in open(iss, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                j = json.loads(line)
            except Exception:
                continue
            t = j.get("t")
            if t == "unit_done":
                units.append(j)
            elif t:
                ev[t] += 1
        print("  事件: " + (", ".join("%s=%d" % (k, v) for k, v in ev.most_common()) or "无"))
        if units:
            tot_cost = sum(u.get("cost_s", 0) for u in units)
            tot_made = sum(u.get("made", 0) for u in units)
            print("  单元: %d 个  总耗时=%.0fs(%.1fh)  总产出=%d  单关均耗时=%.1fs" % (
                len(units), tot_cost, tot_cost / 3600, tot_made, tot_cost / max(1, tot_made)))
            for u in sorted(units, key=lambda x: (x.get("combo", ""), x.get("side", 0))):
                print("    %-10s %sx%s  made=%-4s cost=%-8.0fs by_tier=%s" % (
                    u.get("combo", ""), u.get("side"), u.get("side"), u.get("made"),
                    u.get("cost_s", 0), str(u.get("by_tier", {}))))
