# -*- coding: utf-8 -*-
"""总表 v4.1 三档化（一次性）：删掉 456 行「入门」→ 1,824 集 → 1,368 集，编号重排。

为什么：难度档 v4.1（2026-09-20，ef84174）把四档改三档（普通/困难/噩梦），
「入门」退役（peak 0–1 的纯一眼盘不进任何档）。但 `关卡集总表.csv`（设计规格）
仍是四档口径 → 与 GDD 正文、与游戏内档位、与库目录三处全部对不上。

口径对照：满配 456 组 × 3 档 = 1,368 集 / 136,800 关（原 1,824 集 / 182,400 关）；
发布 292 组 × 3 档 = 876 集 / 87,600 关（原 1,168 集 / 116,800 关）。

用法：python tools/_todo_table_v41.py [--apply]   # 默认 dry-run，只打印将要做的改动
"""
import argparse
import csv
import shutil

CSV = "关卡集总表.csv"
BAK = "关卡集总表.csv.bak_20260923"
RETIRED = {"入门"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="真正写盘（默认只 dry-run）")
    args = ap.parse_args()

    with open(CSV, encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    fields = list(rows[0].keys())
    print("原表：%d 行；列=%s" % (len(rows), fields))

    kept = [r for r in rows if str(r["难度档"]) not in RETIRED]
    dropped = len(rows) - len(kept)
    print("删除「入门」行：%d → 保留 %d 行" % (dropped, len(kept)))

    combos = {r["组合"] for r in kept}
    tiers = {}
    for r in kept:
        tiers[r["难度档"]] = tiers.get(r["难度档"], 0) + 1
    print("保留后：%d 组合 × 档位 %s = %d 集 / %d 关" % (
        len(combos), tiers, len(kept),
        sum(int(r["设计关数"]) for r in kept)))

    # 编号重排（1..N），其余字段原样
    for i, r in enumerate(kept, start=1):
        r["编号"] = str(i)

    # 一致性自检：每（组合,尺寸）必须恰好三档齐全，且每档一行
    bad = []
    per = {}
    for r in kept:
        per.setdefault((r["组合"], r["尺寸"]), []).append(r["难度档"])
    for k, ts in per.items():
        if sorted(ts) != sorted(["普通", "困难", "噩梦"]):
            bad.append((k, ts))
    # ASCII 输出（Windows GBK 控制台打印 ✓/⚠ 会 UnicodeEncodeError，本项目多处同款处理）
    if bad:
        print("[WARN] 有 %d 个（组合,尺寸）三档不全（前 5）：%s" % (len(bad), bad[:5]))
    else:
        print("[OK] 自检：每个（组合,尺寸）恰好 普通/困难/噩梦 三档")

    if not args.apply:
        print("（dry-run，未写盘；加 --apply 执行）")
        return 0

    shutil.copy2(CSV, BAK)
    print("已备份 → %s" % BAK)
    # 保持原编码（UTF-8 BOM）+ LF 换行
    with open(CSV, "w", encoding="utf-8-sig", newline="\n") as f:
        w = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
        w.writeheader()
        w.writerows(kept)
    print("已写回 %s（%d 行）" % (CSV, len(kept)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
