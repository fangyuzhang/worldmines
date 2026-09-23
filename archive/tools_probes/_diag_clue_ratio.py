# -*- coding: utf-8 -*-
"""冗余线索分层诊断（2026-09-16）：按难度档统计 clue_ratio 分布，判定「告警」是否为低档盘误报。
用法：python tools/_diag_clue_ratio.py <harvest_dir> [...]
"""
import collections
import glob
import json
import os
import statistics
import sys

TIERS = [("intro", 0.0, 0.3), ("easy", 0.3, 1.2), ("normal", 1.2, 2.2), ("hard", 2.2, 1e9)]


def tier_of(d):
    for name, lo, hi in TIERS:
        if lo <= d < hi:
            return name
    return "?"


def scan(base):
    rows = collections.defaultdict(list)  # tier -> [(clue_ratio, difficulty)]
    for f in glob.glob(base + r"\**\*.json", recursive=True):
        if "all_report" in f:
            continue
        try:
            j = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        p = j.get("difficulty_profile", {})
        d = float(p.get("difficulty", 0.0))
        cr = float(p.get("clue_ratio", 0.0))
        rows[tier_of(d)].append((cr, d))
    return rows


def stat(tag, rs):
    if not rs:
        print("  %-6s —— 无盘" % tag)
        return
    crs = [c for c, _ in rs]
    over = sum(1 for c in crs if c > 0.5)
    print("  %-6s n=%-4d clue_ratio  min=%.2f med=%.2f max=%.2f  | >0.5: %d (%.0f%%)" % (
        tag, len(rs), min(crs), statistics.median(crs), max(crs), over, 100.0 * over / len(crs)))


for base in sys.argv[1:]:
    if not os.path.isdir(base):
        print("skip (not dir): %s" % base)
        continue
    print("=== %s ===" % os.path.basename(base))
    rows = scan(base)
    for name, _, _ in TIERS:
        stat(name, rows.get(name, []))
