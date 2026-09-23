# -*- coding: utf-8 -*-
# 扫描 harvest_0915b 各目录难度分布（全量）
import json
import glob
import statistics

BASE = r"C:\Users\zjh30\CodeBuddy\20260906184916\_staged_levels\harvest_0915b"
for d in ["batch_o4", "batch_o5x", "batch_o1_7", "batch_o1_8"]:
    ds = []
    for f in glob.glob(BASE + "\\" + d + r"\**\*.json", recursive=True):
        if "all_report" in f:
            continue
        try:
            j = json.load(open(f, encoding="utf-8"))
            ds.append(float(j.get("difficulty_profile", {}).get("difficulty", 0.0)))
        except Exception:
            pass
    if ds:
        print("%s: n=%d  min=%.2f max=%.2f avg=%.2f med=%.2f" % (
            d, len(ds), min(ds), max(ds), statistics.mean(ds), statistics.median(ds)))
    else:
        print("%s: no levels" % d)
