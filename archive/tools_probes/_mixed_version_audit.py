# -*- coding: utf-8 -*-
"""混版集量化（2026-09-24）：把「版本优选」从模糊待办变成可决策表。

背景：o1/o2/o3 等席位的历史集里混着多代生成器产物（旧版删线索弱 → clue_ratio 偏高、难度偏低），
盘本身有效但**同集不同质**。此前的信号是第二批 3,092 关里 644 关离群（20.8% vs 其它批 4–5%）。

做法：对库内每一集算 clue_ratio 的分布，按项目既有**相对口径**（组内中位 +0.15）判离群，
输出「混杂度」排行 + 建议动作，**不自动删任何关卡**（那是产品决策）。

用法：python tools/_mixed_version_audit.py [--lib levels_lib] [--top 20]
"""
import argparse
import glob
import json
import os
import statistics

TIERS = ["easy", "normal", "hard"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", default="levels_lib")
    ap.add_argument("--top", type=int, default=20)
    args = ap.parse_args()

    rows = []
    for path in sorted(glob.glob(os.path.join(args.lib, "*", "*", "*.json"))):
        tier = os.path.basename(path)[:-5]
        if tier not in TIERS:
            continue
        mode = os.path.basename(os.path.dirname(os.path.dirname(path)))
        size = os.path.basename(os.path.dirname(path))
        try:
            levels = json.load(open(path, encoding="utf-8")).get("levels", [])
        except Exception:
            continue
        if len(levels) < 10:
            continue
        ratios = []
        for lv in levels:
            dp = lv.get("difficulty_profile", {}) or {}
            r = dp.get("clue_ratio")
            if isinstance(r, (int, float)):
                ratios.append(float(r))
        if len(ratios) < 10:
            continue
        med = statistics.median(ratios)
        outl = [r for r in ratios if r > med + 0.15]      # 项目相对口径：组内中位 +0.15
        rows.append({
            "set": "%s/%s/%s" % (mode, size, tier), "n": len(ratios),
            "min": min(ratios), "med": med, "max": max(ratios),
            "spread": max(ratios) - min(ratios), "outliers": len(outl),
            "out_pct": 100.0 * len(outl) / len(ratios),
        })

    rows.sort(key=lambda r: (-r["out_pct"], -r["spread"]))
    print("扫描 %d 个集（≥10 关且画像完整）" % len(rows))
    print("相对口径：clue_ratio > 组内中位 +0.15 记离群\n")
    print("%-22s %5s %6s %6s %6s %7s %6s %7s" % ("集", "关数", "min", "中位", "max", "极差", "离群", "离群%"))
    for r in rows[:args.top]:
        print("%-22s %5d %6.3f %6.3f %6.3f %7.3f %6d %6.1f%%" % (
            r["set"], r["n"], r["min"], r["med"], r["max"], r["spread"], r["outliers"], r["out_pct"]))

    heavy = [r for r in rows if r["out_pct"] >= 15]
    mild = [r for r in rows if 5 <= r["out_pct"] < 15]
    print("\n判定（离群% = 该集内疑似旧版盘占比）：")
    print("  · 明显混杂（≥15%%）：%d 个集，疑似旧版共 %d 关 —— 建议列为首批优选对象" % (
        len(heavy), sum(r["outliers"] for r in heavy)))
    print("  · 轻度混杂（5–15%%）：%d 个集，%d 关" % (len(mild), sum(r["outliers"] for r in mild)))
    print("  · 干净（<5%%）：%d 个集" % (len(rows) - len(heavy) - len(mild)))
    print("\n动作建议（需产品拍板，本脚本不改任何文件）：")
    print("  ① 保留全部（同集不同质，但都能玩）；② 剔除离群（集内同质，但每集关数下降）；")
    print("  ③ 按版本拆集（同名多集）——工程量最大。")
    print("  注：判据只有 clue_ratio 一个维度；若要更硬的版本判据，需生成器落盘「版本戳」字段（建议排期）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
