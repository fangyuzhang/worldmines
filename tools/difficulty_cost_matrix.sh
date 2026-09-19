#!/bin/bash
# 定向成本矩阵：按现有产物的窗口命中率，反推"填满 100 关"所需的生成采样量
python3 - <<'PY'
import json, glob, os, collections

def hit(sub, lo, hi):
    return sum(1 for p in sub if lo <= p <= hi)

bdirs = []
for base in ("/root/.local", "/root"):
    for dirpath, dirnames, _ in os.walk(base):
        for d in list(dirnames):
            if d.startswith("batch_"): bdirs.append(os.path.join(dirpath, d))
        if len(dirpath.split(os.sep)) > 12: dirnames[:] = []

cells = collections.defaultdict(list)
for b in bdirs:
    var = os.path.basename(b)
    for f in glob.glob(b + "/**/*.json", recursive=True):
        if "report" in os.path.basename(f): continue
        try: j = json.load(open(f, encoding="utf-8"))
        except Exception: continue
        if not isinstance(j, dict) or "difficulty_profile" not in j: continue
        cells[(var, int((j.get("size") or {}).get("cols", 0) or 0))].append(
            int(j["difficulty_profile"].get("max_complexity", 0) or 0))

print("=== 定向成本矩阵（每格产出 100 关所需的生成采样量；命中率=窗口占比）===")
print("    判读：≤300 优秀（1 倍）；300-1500 可接受（3-5 倍）；>3000 昂贵（>10 倍）；∞ 该单元不可达")
print("%-20s %-3s %6s %10s %10s %10s" % ("批次(变体)", "尺寸", "n", "入门<=2", "困难5-8", "噩梦9-20"))
rows = []
for (var, size) in sorted(cells):
    sub = cells[(var, size)]
    if len(sub) < 150: continue
    n = len(sub)
    c_in, c_hd, c_nm = hit(sub, 0, 2), hit(sub, 5, 8), hit(sub, 9, 20)
    def cost(c):
        return "∞" if c == 0 else str(int(round(100 * n / c)))
    rows.append((var, size, n, cost(c_in), cost(c_hd), cost(c_nm), c_nm / n))
    print("%-20s %-3d %6d %10s %10s %10s" % (var, size, n, cost(c_in), cost(c_hd), cost(c_nm)))

print("\n=== 噩梦档可达性汇总（%d 个单元样本≥150）===" % len(rows))
inf = [r for r in rows if r[5] == "∞"]
cheap = [r for r in rows if r[5] != "∞" and int(r[5]) <= 500]
mid = [r for r in rows if r[5] != "∞" and 500 < int(r[5]) <= 3000]
exp = [r for r in rows if r[5] != "∞" and int(r[5]) > 3000]
print("  ∞（现有产物 0 命中）：%2d 个单元 → %s" % (len(inf), ", ".join("%s@%d" % (r[0][6:], r[1]) for r in inf[:16])))
print("  ≤500 采样（优秀）：%2d 个 → %s" % (len(cheap), ", ".join("%s@%d" % (r[0][6:], r[1]) for r in cheap[:16])))
print("  500-3000（可接受）：%2d 个 → %s" % (len(mid), ", ".join("%s@%d" % (r[0][6:], r[1]) for r in mid[:16])))
print("  >3000（昂贵）：%2d 个 → %s" % (len(exp), ", ".join("%s@%d" % (r[0][6:], r[1]) for r in exp[:16])))

print("\n=== 变体级汇总（跨尺寸平均噩梦命中率）===")
agg = collections.defaultdict(lambda: [0, 0])
for (var, size) in cells:
    sub = cells[(var, size)]
    if len(sub) < 150: continue
    agg[var][0] += hit(sub, 9, 20); agg[var][1] += len(sub)
for var, (a, b) in sorted(agg.items(), key=lambda kv: -kv[1][0] / max(1, kv[1][1])):
    if b < 150: continue
    print("  %-22s 噩梦命中率 %5.1f%%   （n=%d）" % (var, 100.0 * a / b, b))
PY
