# -*- coding: utf-8 -*-
"""补产清单生成（P2，2026-09-16）：列出「部分覆盖」集（1–99 关）与零产出集，按缺口排序。

用法：python tools/_plan_gaps.py [--all|--partial]
默认只列部分覆盖集（差 1–99 关，补产性价比最高）。
"""
import collections
import glob
import json
import os
import re
import sys

ROOT = r"C:\Users\zjh30\CodeBuddy\20260906184916"
CSV = os.path.join(ROOT, "关卡集总表.csv")
DIRS = [
    os.path.join(ROOT, "_staged_levels", "harvest_0916"),
    os.path.join(ROOT, "_staged_levels", "harvest_0916b"),
    os.path.join(ROOT, "_staged_levels", "harvest_o8"),
    os.path.join(ROOT, "_staged_levels", "harvest_0915b"),
]

NAME2RULE = {
    "经典": ("classic", ()),
    "对穿": ("o1", ()), "邻序": ("o2", ()), "分档": ("o3", ()), "变径": ("o4", ()),
    "斜脉": ("o5x", ()), "奇显": ("o6", ()), "钟点": ("o7", []),
    "重心": ("o8", ()), "射距": ("o9", ()), "环游": ("o10", ()),
}
TIER_CN = {"普通": "easy", "困难": "normal", "噩梦": "hard", "入门": "intro"}
TIERS = [("intro", 0.0, 0.3), ("easy", 0.3, 1.2), ("normal", 1.2, 2.2), ("hard", 2.2, 1e9)]


def tier_of(d):
    for name, lo, hi in TIERS:
        if lo <= d < hi:
            return name
    return "?"


def parse_combo(combo_cn):
    base = combo_cn.split("（")[0].strip()
    tokens = [t.strip() for t in re.split(r"[×+]", base) if t.strip()]
    ids = []
    for t in tokens:
        if t not in NAME2RULE:
            return None, []
        ids.append(NAME2RULE[t])
    if not ids:
        return None, []
    clue = ids[0][0]
    globals_ = list(ids[0][1])
    for cid, gs in ids[1:]:
        globals_.append(cid)
        globals_.extend(gs)
    return clue, sorted(set(globals_))


def main():
    mode = "--all" if "--all" in sys.argv else "--partial"
    want = {}
    with open(CSV, encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("编号"):
                continue
            p = line.split(",")
            if len(p) < 7:
                continue
            clue, gl = parse_combo(p[2])
            if clue is None:
                continue
            want[(clue, tuple(gl), int(re.findall(r"\d+", p[3])[0]), TIER_CN[p[5]])] = int(p[6])

    have = collections.Counter()
    for base in DIRS:
        if not os.path.isdir(base):
            continue
        for f in glob.glob(base + r"\**\*.json", recursive=True):
            if "all_report" in f or os.path.basename(f).startswith("report"):
                continue
            try:
                j = json.load(open(f, encoding="utf-8"))
            except Exception:
                continue
            if "clue_rule" not in j:
                continue
            sz = j.get("size", {})
            d = float(j.get("difficulty_profile", {}).get("difficulty", 0.0))
            have[(str(j["clue_rule"]),
                  tuple(sorted(str(g) for g in j.get("global_rules", []) or [])),
                  int(sz.get("cols", 0)), tier_of(d))] += 1

    partial, zero = [], []
    for key, w in want.items():
        h = have.get(key, 0)
        if 0 < h < w:
            partial.append((w - h, h, w, key))
        elif h == 0:
            zero.append(key)

    print("=== 补产清单（可对照 %d 集）===" % len(want))
    print("  部分覆盖: %d 集 | 零产出: %d 集" % (len(partial), len(zero)))
    if mode == "--partial":
        print("\n【部分覆盖集】按缺口升序（先补缺口小的）")
        for gap, h, w, k in sorted(partial):
            print("  缺%-4d 现%-4d/%-4d  %-4s | %-8s | %dx%d | %s" % (
                gap, h, w, k[0], "+".join(k[1]) or "-", k[2], k[2], k[3]))
        by_combo = collections.Counter()
        for gap, h, w, k in partial:
            by_combo[(k[0], k[1], k[2])] += gap
        print("\n【按（组合,尺寸）汇总缺口】")
        for (c, g, s), tot in by_combo.most_common():
            n_units = sum(1 for gap, h, w, k in partial if (k[0], k[1], k[2]) == (c, g, s))
            print("  %-4s | %-8s | %dx%d | %d 档位 | 共缺 %d 关" % (
                c, "+".join(g) or "-", s, s, n_units, tot))
    else:
        print("\n【零产出集】")
        for k in sorted(zero):
            print("  %-4s | %-8s | %dx%d | %s" % (k[0], "+".join(k[1]) or "-", k[2], k[2], k[3]))
    print("\n总缺口: %d 关" % (sum(g for g, _, _, _ in partial) + len(zero) * 100))


if __name__ == "__main__":
    main()
