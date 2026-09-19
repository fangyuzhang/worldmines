"""_xvalidate_metrics2.py —— 交叉验证第二轮：归因 + 天花板 + 常量可比性

1) 我们的 difficulty 到底在测什么？与「步数/轮数/最大批量」的秩相关（grind 归因）
2) 误标案例量化：grind-hard（我们 hard 但峰值浅）/ deep-intro（我们 intro 但峰很深）
3) 尺寸天花板（峰值口径）：各尺寸的峰值分布与最大值 → 验证「尺寸限制难度」是否在我们数据里成立
4) 对方常量可比性：同一阈值下，我们库 vs 对方库的「噩梦占比」对比（判断能否直接套用）
"""
import json, os, sys, glob, collections, math

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STAGED = os.path.join(ROOT, "_staged_levels")


def tier_ours(d):
    if d < 0.3: return "intro"
    if d < 1.2: return "easy"
    if d < 2.2: return "normal"
    return "hard"


def parse_hist(s):
    out = {}
    for part in str(s).split(","):
        part = part.strip()
        if not part or "x" not in part: continue
        a, b = part.split("x", 1)
        try: out[int(a)] = int(b)
        except ValueError: pass
    return out


def spearman(pairs):
    n = len(pairs)
    if n < 3: return float("nan")
    def ranks(xs):
        order = sorted(range(n), key=lambda i: xs[i]); r = [0.0]*n; i = 0
        while i < n:
            j = i
            while j+1 < n and xs[order[j+1]] == xs[order[i]]: j += 1
            avg = (i+j)/2.0 + 1
            for k in range(i, j+1): r[order[k]] = avg
            i = j+1
        return r
    rx, ry = ranks([p[0] for p in pairs]), ranks([p[1] for p in pairs])
    mx, my = sum(rx)/n, sum(ry)/n
    num = sum((rx[i]-mx)*(ry[i]-my) for i in range(n))
    den = math.sqrt(sum((v-mx)**2 for v in rx)*sum((v-my)**2 for v in ry))
    return num/den if den else float("nan")


dirs = []
for pat in ["harvest_0915", "harvest_0915b", "harvest_0916", "harvest_0916b", "harvest_0917",
            "harvest_o8", "o1_batch_20260914"]:
    p = os.path.join(STAGED, pat)
    if os.path.isdir(p): dirs.extend(glob.glob(p + "/batch_*"))

L = []
for d in dirs:
    for f in glob.glob(d + "/*/*/*.json"):
        if "report" in os.path.basename(f): continue
        try: j = json.load(open(f, encoding="utf-8"))
        except Exception: continue
        if not isinstance(j, dict) or "difficulty_profile" not in j: continue
        dp = j["difficulty_profile"]
        hist = parse_hist(dp.get("histogram", ""))
        L.append({
            "difficulty": float(dp.get("difficulty", 0.0)),
            "peak": int(dp.get("max_complexity", 0) or 0),
            "rounds": int(dp.get("rounds", 0) or 0),
            "steps": sum(hist.values()),
            "max_batch": int(dp.get("max_batch", 0) or 0),
            "size": int((j.get("size") or {}).get("cols", 0) or 0),
            "tier": tier_ours(float(dp.get("difficulty", 0.0))),
        })
N = len(L)
print("样本 %d 关" % N)
print("=" * 80)

# ── 1) 归因：difficulty 与各结构量的秩相关 ──
print("[1] difficulty 与结构量的秩相关（判断它在测什么）")
for name, key in [("轮数 rounds", "rounds"), ("总步数 steps", "steps"),
                  ("最大批量 max_batch", "max_batch"), ("峰值复杂度 peak", "peak")]:
    print("    Spearman(difficulty, %-14s) = %.3f" % (name, spearman([(l["difficulty"], l[key]) for l in L])))

# ── 2) 误标案例 ──
grind_hard = [l for l in L if l["tier"] == "hard" and l["peak"] <= 2]
deep_intro = [l for l in L if l["tier"] == "intro" and l["peak"] >= 8]
deep_easy = [l for l in L if l["tier"] == "easy" and l["peak"] >= 8]
print("\n[2] 误标案例（两套度量分歧最大的两侧）")
print("    ① grind-hard（我们判 hard，峰值 ≤2 = 对方「一眼/普通」级）：%d 关（占 hard 的 %.1f%%）"
      % (len(grind_hard), 100.0*len(grind_hard)/max(1, sum(1 for l in L if l["tier"]=="hard"))))
print("       这些盘：中位轮数 %d、中位总步数 %d、中位 max_batch %d"
      % (sorted(l["rounds"] for l in grind_hard)[len(grind_hard)//2] if grind_hard else 0,
         sorted(l["steps"] for l in grind_hard)[len(grind_hard)//2] if grind_hard else 0,
         sorted(l["max_batch"] for l in grind_hard)[len(grind_hard)//2] if grind_hard else 0))
print("    ② deep-intro（我们判 intro（<0.3），峰值 ≥8）：%d 关；deep-easy（easy 且峰值 ≥8）：%d 关"
      % (len(deep_intro), len(deep_easy)))
print("       这些盘：中位轮数 %d、中位总步数 %d（短而深 → 被我们判成低难度）"
      % (sorted(l["rounds"] for l in deep_intro)[len(deep_intro)//2] if deep_intro else 0,
         sorted(l["steps"] for l in deep_intro)[len(deep_intro)//2] if deep_intro else 0))

# ── 3) 尺寸天花板（峰值口径）──
print("\n[3] 峰值口径的尺寸天花板（验证「尺寸限制难度」）")
for sz in (5, 6, 7, 8, 9):
    sub = [l["peak"] for l in L if l["size"] == sz]
    if not sub: continue
    sub.sort()
    p50, p90, mx = sub[len(sub)//2], sub[int(len(sub)*0.9)], sub[-1]
    print("    %d×%d：n=%5d  峰值 中位 %2d / P90 %2d / 最大 %2d" % (sz, sz, len(sub), p50, p90, mx))
print("    我们的 difficulty 口径天花板（对照）：")
for sz in (5, 6, 7, 8, 9):
    sub = sorted(l["difficulty"] for l in L if l["size"] == sz)
    if not sub: continue
    print("    %d×%d：difficulty 中位 %.2f / P90 %.2f / 最大 %.2f" % (sz, sz, sub[len(sub)//2], sub[int(len(sub)*0.9)], sub[-1]))

# ── 4) 常量可比性：同阈值下两库占比 ──
print("\n[4] 常量可比性（能否直接套用对方的 MIN 阈值）")
for thr, label in [(2, "普通 MIN=2"), (4, "困难 MIN=4"), (5, "噩梦 MIN=5"), (6, "噩梦 MIN=6")]:
    n = sum(1 for l in L if l["peak"] >= thr)
    print("    我们的库：峰值 ≥%d 的占 %.1f%%（%d/%d）" % (thr, 100.0*n/N, n, N))
print("    对方库（文档 §6.2 实测）：普通 51.4%% / 困难 47.5%% / 噩梦 **1.1%%**（3,634/323,279）")
print("    → 阈值不可直接移植；必须用我们自己的分布标定（否则噩梦占比差 30 倍以上）")
