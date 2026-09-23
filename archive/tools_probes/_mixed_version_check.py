# -*- coding: utf-8 -*-
"""混杂度复核：把 clue_ratio 的离散按 **peak 分组**归一，判定到底是「版本混杂」还是「窗口内峰值差异」。

逻辑：v4.1 档位 = 峰值窗口（easy 2-3 / normal 4-5 / hard 6-20）。若一个 hard 集里既有 peak=6 又有
peak=20，clue_ratio 天然会差很多（删线索「达标即停」→ 低 peak 停得早、线索多）——这**不是**版本信号。
只有当**同一 peak 组内**仍然离散得很开时，才支持"同集混了多代生成器产物"。

用法：python tools/_mixed_version_check.py [--lib levels_lib] [--sets s1/6/hard ...]
"""
import argparse
import glob
import json
import os
import statistics
import collections

TIERS = ["easy", "normal", "hard"]


def load(path):
    return json.load(open(path, encoding="utf-8")).get("levels", [])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", default="levels_lib")
    ap.add_argument("--sets", nargs="*", default=[])
    ap.add_argument("--top", type=int, default=8)
    args = ap.parse_args()

    # 先全库扫一遍，取「离群%」最高的若干个集（与 _mixed_version_audit 同口径）
    cand = []
    for path in sorted(glob.glob(os.path.join(args.lib, "*", "*", "*.json"))):
        tier = os.path.basename(path)[:-5]
        if tier not in TIERS:
            continue
        key = "%s/%s/%s" % (os.path.basename(os.path.dirname(os.path.dirname(path))),
                            os.path.basename(os.path.dirname(path)), tier)
        if args.sets and key not in args.sets:
            continue
        levels = load(path)
        rs = [float((lv.get("difficulty_profile") or {}).get("clue_ratio", -1)) for lv in levels]
        rs = [r for r in rs if r >= 0]
        if len(rs) < 10:
            continue
        med = statistics.median(rs)
        cand.append((100.0 * sum(1 for r in rs if r > med + 0.15) / len(rs), key, levels))

    cand.sort(key=lambda x: -x[0])
    print("复核前 %d 个「离群%%最高」的集：按 peak 分组后看离散是否仍然存在\n" % args.top)
    for out_pct, key, levels in cand[:args.top]:
        by_peak = collections.defaultdict(list)
        for lv in levels:
            dp = lv.get("difficulty_profile") or {}
            if "max_complexity" in dp and "clue_ratio" in dp:
                by_peak[int(dp["max_complexity"])].append(float(dp["clue_ratio"]))
        allr = [r for v in by_peak.values() for r in v]
        print("%s  总体 n=%d 极差=%.3f（粗口径离群 %.1f%%）" % (
            key, len(allr), max(allr) - min(allr), out_pct))
        for peak in sorted(by_peak):
            v = by_peak[peak]
            if len(v) < 2:
                print("    peak=%-3d n=%-3d  （单样本）" % (peak, len(v)))
                continue
            in_out = sum(1 for r in v if r > statistics.median(v) + 0.15)
            print("    peak=%-3d n=%-3d min=%.3f 中位=%.3f max=%.3f 极差=%.3f 组内离群=%d" % (
                peak, len(v), min(v), statistics.median(v), max(v), max(v) - min(v), in_out))
        # 判据：组内最大极差 < 0.25 → 离散主要是峰值造成的（非版本信号）
        worst = max((max(v) - min(v) for v in by_peak.values() if len(v) >= 2), default=0.0)
        verdict = "组内仍离散 → 支持版本混杂" if worst >= 0.25 else "组内基本一致 → 离散来自峰值分布（非版本信号）"
        print("    → 组内最大极差 %.3f：%s\n" % (worst, verdict))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
