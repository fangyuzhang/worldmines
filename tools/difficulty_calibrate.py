"""difficulty_calibrate.py —— 难度常量标定（数据驱动分位法）

输入：已收割产物 JSON（每关含 difficulty_profile.histogram / max_complexity / rounds / size）
输出：
  1) 每个 (变体 × 尺寸) 单元的峰值分布分位（P40/P70/P90/P95/P99 + MAX）
  2) 按分位法给出的四档常量草案（入门/正常/困难/噩梦 的峰值门槛）
  3) 供给可行性：分位法下各档"采样命中率" → 反推填满一集 100 关所需的生成采样量
  4) 对比现状：现行 difficulty 标量分档下各档占比（暴露失衡，如 hard=0% 的格）
"""
import json, os, sys, glob, collections

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STAGED = os.path.join(ROOT, "_staged_levels")

VARIANT_KEYS = ["variant", "mod", "mode", "operator", "op", "ruleset", "rules", "rule"]


def parse_hist(s):
    out = {}
    for part in str(s).split(","):
        part = part.strip()
        if not part or "x" not in part: continue
        a, b = part.split("x", 1)
        try: out[int(a)] = int(b)
        except ValueError: pass
    return out


def cell_of(path, j):
    """(variant, size)"""
    size = int((j.get("size") or {}).get("cols", 0) or 0)
    var = ""
    for k in VARIANT_KEYS:
        v = j.get(k)
        if isinstance(v, str) and v:
            var = v; break
        if isinstance(v, list) and v and isinstance(v[0], str):
            var = "+".join(v); break
    if not var:  # 回退：目录名 batch_xxx → xxx
        parts = path.replace("\\", "/").split("/")
        for p in parts:
            if p.startswith("batch_"):
                var = p[6:]; break
    return var or "?", size


levels = []
sample_printed = False
dirs = []
for pat in ["harvest_0915", "harvest_0915b", "harvest_0916", "harvest_0916b", "harvest_0917",
            "harvest_o8", "o1_batch_20260914"]:
    p = os.path.join(STAGED, pat)
    if os.path.isdir(p): dirs.extend(glob.glob(p + "/batch_*"))

for d in dirs:
    for f in glob.glob(d + "/*/*/*.json"):
        if "report" in os.path.basename(f): continue
        try: j = json.load(open(f, encoding="utf-8"))
        except Exception: continue
        if not isinstance(j, dict) or "difficulty_profile" not in j: continue
        dp = j["difficulty_profile"]
        if not sample_printed:
            print("JSON 顶层键样例：%s" % ", ".join(sorted(j.keys())[:14]))
            sample_printed = True
        var, size = cell_of(f, j)
        hist = parse_hist(dp.get("histogram", ""))
        levels.append({
            "variant": var, "size": size,
            "peak": int(dp.get("max_complexity", 0) or 0),
            "difficulty": float(dp.get("difficulty", 0.0)),
            "steps": sum(hist.values()),
            "target": float(dp.get("target_difficulty", 0.0) or 0.0),
            "tier_old": ("intro" if float(dp.get("difficulty", 0.0)) < 0.3 else
                         "easy" if float(dp.get("difficulty", 0.0)) < 1.2 else
                         "normal" if float(dp.get("difficulty", 0.0)) < 2.2 else "hard"),
        })

N = len(levels)
print("\n样本 %d 关，%d 个 (变体×尺寸) 单元" % (N, len({(l["variant"], l["size"]) for l in levels})))


def q(xs, p):
    if not xs: return 0
    xs = sorted(xs)
    i = min(len(xs) - 1, max(0, int(round(p * (len(xs) - 1)))))
    return xs[i]


cells = collections.defaultdict(list)
for l in levels: cells[(l["variant"], l["size"])].append(l)

# ── 1) 单元级分位（样例展示 Top 变量）+ 数据量告警 ──
print("\n[1] 单元分位（峰值；仅展示样本 ≥150 的单元，按变体聚合 5×5~9×9）")
thin = []
print("%-10s %-4s %6s %5s %5s %5s %5s %5s %5s" % ("变体", "尺寸", "n", "P40", "P70", "P90", "P95", "P99", "MAX"))
for (var, size) in sorted(cells):
    sub = cells[(var, size)]
    if len(sub) < 150:
        thin.append((var, size, len(sub))); continue
    pk = [l["peak"] for l in sub]
    print("%-10s %-4d %6d %5d %5d %5d %5d %5d %5d" % (
        var, size, len(sub), q(pk, .40), q(pk, .70), q(pk, .90), q(pk, .95), q(pk, .99), max(pk)))
if thin:
    print("  ⚠ 样本不足 150 的单元 %d 个：%s" % (len(thin), ", ".join("%s@%d(n=%d)" % t for t in thin[:10])))

# ── 2) 分位法常量草案（全局口径 + 每单元微调）──
print("\n[2] 分位法档位草案（每单元用自身分布；此处给全局默认权重）")
print("    噩梦 = 峰值 ≥ P90；困难 = P70~P90；正常 = P40~P70；入门 = < P40")
print("    全局参考（全样本峰值分位）：P40=%d  P70=%d  P90=%d  P95=%d  MAX=%d"
      % (q([l["peak"] for l in levels], .40), q([l["peak"] for l in levels], .70),
         q([l["peak"] for l in levels], .90), q([l["peak"] for l in levels], .95),
         max(l["peak"] for l in levels)))

# ── 3) 供给可行性：分位法下每档采样命中率 → 填满一集 100 关所需采样 ──
print("\n[3] 供给可行性（分位法：命中率 = 分位带宽；填 100 关所需采样量 = 100 / 命中率）")
for name, frac in [("噩梦", 0.10), ("困难", 0.20), ("正常", 0.30), ("入门", 0.40)]:
    print("    %s：命中率 ≈ %2.0f%% → 每集 100 关需生成 ≈ %d 次采样" % (name, frac * 100, round(100 / frac)))
print("    （对照现状：按 target 定向生成 ≈ 100~150 次采样/集；分位法的额外成本主要在噩梦档 10×）")

# ── 4) 现状对比：现行标量分档的失衡（按单元）──
print("\n[4] 现状失衡（现行 difficulty 标量分档，各单元 hard 占比）")
bad = []
for (var, size) in sorted(cells):
    sub = cells[(var, size)]
    if len(sub) < 150: continue
    h = sum(1 for l in sub if l["tier_old"] == "hard")
    if h / len(sub) < 0.02:
        bad.append("%s@%d=%.1f%%" % (var, size, 100.0 * h / len(sub)))
print("    hard 占比 < 2%% 的单元 %d 个：%s" % (len(bad), ", ".join(bad[:12]) if bad else "无"))
print("    （分位法下这些单元按构造都有 ~10%% 噩梦供给 → 失衡自动消除）")

# ── 5) 长度轴独立性检查（确认 steps 与 peak 不是同一维度）──
print("\n[5] 长度轴独立性：steps 与 peak 的联合分布（全样本）")
buck_p = [(0, 1), (2, 3), (4, 6), (7, 999)]
buck_s = [(0, 2), (3, 6), (7, 15), (16, 999)]
print("%-10s" % "peak\\steps" + "".join("%12s" % ("%d-%d" % b if b[1] < 999 else ">=%d" % b[0]) for b in buck_s))
for (plo, phi) in buck_p:
    row = [0] * len(buck_s)
    for l in levels:
        if plo <= l["peak"] <= phi:
            for i, (slo, shi) in enumerate(buck_s):
                if slo <= l["steps"] <= shi: row[i] += 1; break
    print("%-10s" % ("%d-%d" % (plo, phi) if phi < 999 else ">=%d" % plo) + "".join("%12d" % v for v in row))
print("    → 若两轴大致独立（各象限都有量），则「深度定档 + 长度画像」成立，不会重演长度混入难度")
