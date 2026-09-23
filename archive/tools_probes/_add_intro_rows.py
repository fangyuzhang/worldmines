# -*- coding: utf-8 -*-
"""总表新增「入门」档集行（P1 选项 A，2026-09-16）。

规则：每个（组合, 尺寸）组内在「普通」行**前**插入一行「入门」，档位序改为
「入门 → 普通 → 困难 → 噩梦」（与 Difficulty.TIERS 的四档顺序一致）；
全文**重排编号**（编号无外部引用，已核）。

- 456 组 × 4 档 = 1824 集（原 1368）。
- 原表备份为 `关卡集总表.csv.bak_20260916`（可回滚）。
用法：python tools/_add_intro_rows.py [--dry]
"""
import os
import shutil
import sys

CSV = r"C:\Users\zjh30\CodeBuddy\20260906184916\关卡集总表.csv"
BAK = CSV + ".bak_20260916"
DRY = "--dry" in sys.argv


def main():
    raw = open(CSV, encoding="utf-8-sig").read().splitlines()
    header = raw[0]
    rows = [l.split(",") for l in raw[1:] if l.strip()]

    out = []
    no = 0
    prev_key = None
    groups = 0
    for p in rows:
        if len(p) < 7:
            print("!! 跳过错行: %s" % ",".join(p))
            continue
        key = (p[2], p[3])  # (组合, 尺寸)
        if key != prev_key:
            groups += 1
            prev_key = key
            no += 1
            # 入门行：编号 / 层 / 组合 / 尺寸 / 雷数 / 入门 / 设计关数
            out.append([str(no), p[1], p[2], p[3], p[4], "入门", p[6]])
        no += 1
        out.append([str(no)] + p[1:])

    print("原 %d 集 → 新 %d 集（+%d 入门集，%d 个（组合,尺寸）组）" % (
        len(rows), len(out), len(out) - len(rows), groups))
    if DRY:
        print("[dry-run] 未写入。前 6 行预览：")
        print(header)
        for p in out[:6]:
            print(",".join(p))
        return
    if not os.path.exists(BAK):
        shutil.copy(CSV, BAK)
        print("已备份 → %s" % os.path.basename(BAK))
    with open(CSV, "w", encoding="utf-8-sig", newline="") as f:
        f.write(header + "\n")
        for p in out:
            f.write(",".join(p) + "\n")
    print("已写入 %s" % os.path.basename(CSV))


if __name__ == "__main__":
    main()
