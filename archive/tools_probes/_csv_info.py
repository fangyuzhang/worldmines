# -*- coding: utf-8 -*-
# CSV 总表概览：行数 / 层分布 / 组合清单 / 关键列统计
import sys
import csv
from collections import Counter

sys.stdout.reconfigure(encoding="utf-8")

PATH = r"C:\Users\zjh30\Desktop\关卡集总表.csv"

rows = []
with open(PATH, "r", encoding="utf-8-sig") as f:
    reader = csv.DictReader(f)
    rows = list(reader)

print("TOTAL ROWS:", len(rows))
print("COLUMNS:", list(rows[0].keys()))

layers = Counter(r["层"] for r in rows)
print("\n=== LAYERS ===")
for k, v in sorted(layers.items()):
    print("  %s : %d" % (k, v))

combos = []
for r in rows:
    if r["组合"] not in combos:
        combos.append(r["组合"])
print("\n=== COMBOS (%d) ===" % len(combos))
for c in combos:
    print("  " + c)

sizes = Counter(r["尺寸"] for r in rows)
print("\n=== SIZES ===")
for k, v in sorted(sizes.items()):
    print("  %s : %d" % (k, v))

mines = Counter((r["尺寸"], r["雷数"]) for r in rows)
print("\n=== SIZE/MINES pairs ===")
for k, v in sorted(mines.items()):
    print("  %s x %s -> %s : %d" % (k[0], k[1], v, v))

diffs = Counter(r["难度档"] for r in rows)
print("\n=== DIFFICULTY ===")
for k, v in diffs.items():
    print("  %s : %d" % (k, v))

tot = sum(int(r["设计关数"]) for r in rows if str(r["设计关数"]).strip().isdigit())
print("\nTOTAL DESIGNED LEVELS:", tot)
