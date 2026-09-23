# -*- coding: utf-8 -*-
"""关卡集登记核对（总表 ↔ 产物），2026-09-16。

用途：回答「入库还差多少」——把《关卡集总表.csv》（设计规格，1368 集 × 100 关）
与 `_staged_levels/` 下已收割产物做双向核对：
  ① 逐集覆盖：设计 100 关 vs 实际关数（达标 / 部分 / 零）；
  ② 无归属产物：档位或组合在总表中找不到对应集（口径不同步的信号，如 intro 档）；
  ③ 总覆盖率：产物总关数 / 设计总量。

产物侧真相以 JSON 字段为准（clue_rule + global_rules + size），不依赖目录命名。

用法：python tools/_audit_catalog.py [产物根目录 ...]
默认：_staged_levels/harvest_0916  harvest_o8  harvest_0915b
"""
import collections
import glob
import json
import os
import re
import sys

ROOT = r"C:\Users\zjh30\CodeBuddy\20260906184916"
CSV = os.path.join(ROOT, "关卡集总表.csv")
DEFAULT_DIRS = [
    os.path.join(ROOT, "_staged_levels", "harvest_0916"),
    os.path.join(ROOT, "_staged_levels", "harvest_0916b"),
    os.path.join(ROOT, "_staged_levels", "harvest_o8"),
    os.path.join(ROOT, "_staged_levels", "harvest_0915b"),
]

# 总表中文组合名 → (clue_rule, global_rules)。仅列已确认映射；未列出的会单独报「未映射」。
NAME2RULE = {
    "经典": ("classic", ()),
    "对穿": ("o1", ()), "邻序": ("o2", ()), "分档": ("o3", ()), "变径": ("o4", ()),
    "斜脉": ("o5x", ()), "奇显": ("o6", ()), "钟点": ("o7", ()), "重心": ("o8", ()),
    "射距": ("o9", ()), "环游": ("o10", ()),
}
TIER_CN = {"普通": "easy", "困难": "normal", "噩梦": "hard", "入门": "intro"}


def load_catalog():
    """解析总表 → 集列表 [{no, layer, combo_cn, side, mines, tier_cn, want}]。"""
    rows = []
    with open(CSV, encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("编号"):
                continue
            parts = line.split(",")
            if len(parts) < 7:
                continue
            rows.append({
                "no": parts[0], "layer": parts[1], "combo": parts[2],
                # 尺寸列是「7×7」——必须取**第一个**数字串，直接去非数字会得到 "77"。
                "side": int(re.findall(r"\d+", parts[3])[0]), "mines": int(parts[4]),
                "tier_cn": parts[5], "want": int(parts[6]),
            })
    return rows


def parse_combo(combo_cn):
    """总表组合名 → (clue_id, globals)。支持 'X（底座：经典）' / 'X × Y' / 'X + Y' / 'X × Y + Z'。

    返回 (clue, globals)；任一部分无法映射 → (None, [])，由调用方记为「未映射」。
    """
    base = combo_cn.split("（")[0].strip()          # 去「（底座：经典）」
    tokens = [t.strip() for t in re.split(r"[×+]", base) if t.strip()]
    ids = []
    for t in tokens:
        if t not in NAME2RULE:
            return None, []
        ids.append(NAME2RULE[t])
    if not ids:
        return None, []
    # 约定：第一个 token 是主线索规则，其余进 globals（与 batch_all_variants 的 CLUES/GLOBALS 一致）
    clue = ids[0][0]
    globals_ = list(ids[0][1])
    for cid, gs in ids[1:]:
        globals_.append(cid)
        globals_.extend(gs)
    return clue, sorted(set(globals_))


def scan_products(dirs):
    """扫描产物 → {(clue, tuple(globals), side, tier): count}，档位按 difficulty 实算。"""
    TIERS = [("intro", 0.0, 0.3), ("easy", 0.3, 1.2), ("normal", 1.2, 2.2), ("hard", 2.2, 1e9)]

    def tier_of(d):
        for name, lo, hi in TIERS:
            if lo <= d < hi:
                return name
        return "?"

    agg = collections.Counter()
    files = 0
    for base in dirs:
        if not os.path.isdir(base):
            continue
        for f in glob.glob(base + r"\**\*.json", recursive=True):
            if "all_report" in f or "report" in os.path.basename(f):
                continue
            try:
                j = json.load(open(f, encoding="utf-8"))
            except Exception:
                continue
            if "clue_rule" not in j:
                continue
            files += 1
            clue = str(j.get("clue_rule", "classic"))
            globals_ = tuple(sorted(str(g) for g in j.get("global_rules", []) or []))
            sz = j.get("size", {})
            side = int(sz.get("cols", 0))
            d = float(j.get("difficulty_profile", {}).get("difficulty", 0.0))
            agg[(clue, globals_, side, tier_of(d))] += 1
    return agg, files


def main():
    dirs = sys.argv[1:] or DEFAULT_DIRS
    cat = load_catalog()
    prod, n_files = scan_products(dirs)

    unmapped = collections.Counter()
    want_sets = collections.Counter()      # 设计规格（标准档，不含 intro）
    for r in cat:
        clue, gl = parse_combo(r["combo"])
        if clue is None:
            unmapped[r["combo"]] += 1
            continue
        tier = TIER_CN.get(r["tier_cn"], "?")
        want_sets[(clue, tuple(gl), r["side"], tier)] = r["want"]

    print("=== 关卡集登记核对（%s）===" % ", ".join(os.path.basename(d) for d in dirs))
    print("  总表: %d 集 / 设计总量 %d 关（含未映射 %d 集）" % (
        len(cat), sum(r["want"] for r in cat), sum(unmapped.values())))
    print("  产物: %d 个关卡 JSON" % n_files)
    if unmapped:
        print("  未映射组合（需补 NAME2RULE）: " + ", ".join("%s×%d" % (k, v) for k, v in unmapped.most_common(6)))

    total_want = sum(want_sets.values())
    total_have = sum(prod.values())
    print("  可对照子集: 设计 %d 关（%d 集）" % (total_want, len(want_sets)))

    done = partial = zero = 0
    gaps = []
    for key, want in want_sets.items():
        have = prod.get(key, 0)
        if have >= want:
            done += 1
        elif have > 0:
            partial += 1
            gaps.append((have, want, key))
        else:
            zero += 1
    print("  覆盖: 达标 %d 集 | 部分 %d 集 | 零 %d 集" % (done, partial, zero))
    print("  覆盖率: %d / %d 关（%.1f%%）" % (total_have, total_want, 100.0 * total_have / max(1, total_want)))
    if gaps:
        print("  部分覆盖 Top（关数/设计, 集）:")
        for have, want, key in sorted(gaps, key=lambda x: -x[0])[:8]:
            print("    %-4d/%-4d  %s | %s | %dx%d | %s" % (
                have, want, key[0], "+".join(key[1]) or "-", key[2], key[2], key[3]))

    # 无归属产物：档位/组合在总表里找不到对应集
    orphan = collections.Counter()
    for key, n in prod.items():
        if key not in want_sets:
            orphan[key] += n
    print("  无归属产物: %d 关" % sum(orphan.values()))
    by_reason = collections.Counter()
    for key, n in orphan.items():
        if key[3] == "intro":
            by_reason["入门档（总表无 intro 集）"] += n
        else:
            by_reason["其它（组合/尺寸不在总表）"] += n
    for reason, n in by_reason.most_common():
        print("    %s: %d 关" % (reason, n))
    detail = [k for k in orphan if k[3] != "intro"]
    for key in sorted(detail, key=lambda k: -orphan[k])[:6]:
        print("      %s | %s | %dx%d | %s : %d 关" % (
            key[0], "+".join(key[1]) or "-", key[2], key[2], key[3], orphan[key]))


if __name__ == "__main__":
    main()
