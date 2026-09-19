"""_xvalidate_metrics.py —— 双度量交叉验证（我们 vs 14MV2 反逆向口径）

在同一批真实产物上同时算两套度量：
  A) 我们：difficulty = Σ(1/批量)                        → 四档 intro/easy/normal/hard
  B) 对方：hist(c)=每轮必要线索数直方图 → max_complexity（峰值）+ RankScore
做法：
  1) 字段存在率（difficulty / histogram / max_complexity / rounds / profile）
  2) 我们的四档 × 对方的 max_complexity 分桶 → 交叉表（看两套标签是否一致）
  3) 秩相关：Spearman(difficulty, max_complexity)、Spearman(difficulty, RankScore)
  4) 用对方政策回判我们的盘（MIN/MAX 常量套用）→ 各档"会被对方判成什么"
  5) RankScore（W=3 vs W=15，含截断）与我们的 difficulty 排序差异
"""
import json, os, sys, glob, collections, math

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STAGED = os.path.join(ROOT, "_staged_levels")

# 我们侧四档（core/difficulty.gd）
def tier_ours(d):
    if d < 0.3: return "intro"
    if d < 1.2: return "easy"
    if d < 2.2: return "normal"
    return "hard"

# 对方侧常量（Minesweeper Variants 2 逆向，下标=边长；9 用 8 的值）
MIN  = {5:5, 6:5, 7:6, 8:6, 9:6}      # 噩梦 MIN
# 对方"档位回判"用三档（普通/困难/噩梦）——取噩梦 MIN 作为"够不够噩梦"的门槛
def parse_hist(s):
    """'4x2,3x1,2x1,1x4' → {c: steps}"""
    out = {}
    for part in str(s).split(","):
        part = part.strip()
        if not part or "x" not in part: continue
        a, b = part.split("x", 1)
        try: out[int(a)] = int(b)
        except ValueError: pass
    return out

def rank_score(hist, W):
    """对方 RankScore = Σ min(10^|c|, 10^W) × 步数（|c|<=1 记 1）"""
    cap = 10.0 ** W
    s = 0.0
    for c, n in hist.items():
        ac = abs(c)
        w = 1.0 if ac <= 1 else min(10.0 ** ac, cap)
        s += w * n
    return s

def spearman(pairs):
    n = len(pairs)
    if n < 3: return float("nan")
    def ranks(xs):
        order = sorted(range(n), key=lambda i: xs[i])
        r = [0.0] * n
        i = 0
        while i < n:
            j = i
            while j + 1 < n and xs[order[j + 1]] == xs[order[i]]:
                j += 1
            avg = (i + j) / 2.0 + 1
            for k in range(i, j + 1): r[order[k]] = avg
            i = j + 1
        return r
    rx, ry = ranks([p[0] for p in pairs]), ranks([p[1] for p in pairs])
    mx, my = sum(rx)/n, sum(ry)/n
    num = sum((rx[i]-mx)*(ry[i]-my) for i in range(n))
    den = math.sqrt(sum((v-mx)**2 for v in rx) * sum((v-my)**2 for v in ry))
    return num/den if den else float("nan")

# ── 采样：本地已收割的官方批次 ──
dirs = []
for pat in ["harvest_0915", "harvest_0915b", "harvest_0916", "harvest_0916b", "harvest_0917",
            "harvest_o8", "o1_batch_20260914"]:
    p = os.path.join(STAGED, pat)
    if os.path.isdir(p): dirs.extend(glob.glob(p + "/batch_*"))

levels = []
miss = collections.Counter()
for d in dirs:
    for f in glob.glob(d + "/*/*/*.json"):
        if "report" in os.path.basename(f): continue
        try: j = json.load(open(f, encoding="utf-8"))
        except Exception: continue
        if not isinstance(j, dict) or "difficulty_profile" not in j: continue
        dp = j["difficulty_profile"]
        lv = {"difficulty": float(dp.get("difficulty", 0.0)),
              "max_complexity": int(dp.get("max_complexity", 0) or 0),
              "rounds": int(dp.get("rounds", 0) or 0),
              "max_batch": int(dp.get("max_batch", 0) or 0),
              "hist": parse_hist(dp.get("histogram", "")),
              "prof": parse_hist(dp.get("profile", "")),
              "size": int((j.get("size") or {}).get("cols", 0) or 0),
              "dir": os.path.basename(d)}
        for k in ("difficulty", "histogram", "max_complexity", "rounds", "profile"):
            if k == "difficulty": ok = "difficulty" in dp
            else: ok = bool(dp.get(k))
            if not ok: miss[k] += 1
        levels.append(lv)

N = len(levels)
print("=" * 88)
print("样本：%d 关（本地已收割官方批次 %d 个批次目录）" % (N, len(dirs)))
print("字段缺失情况：%s" % (dict(miss) if miss else "无缺失"))
print("=" * 88)

# ── 1) 分布总览 ──
by_tier = collections.Counter(tier_ours(l["difficulty"]) for l in levels)
mc_hist = collections.Counter(l["max_complexity"] for l in levels)
print("\n[1] 我们四档分布：%s" % dict(by_tier))
print("    对方口径 max_complexity（每轮必要线索数峰值）分布（前 12 档）：")
for c, n in sorted(mc_hist.items())[:12]:
    print("      c=%-3d %6d 关  (%.1f%%)" % (c, n, 100.0*n/N))

# ── 2) 交叉表：我们的档 × 对方峰值复杂度 ──
print("\n[2] 交叉表：我们四档 × 对方峰值 max_complexity（行=我们的档，列=c 区间）")
buckets = [(0,1),(2,2),(3,4),(5,7),(8,999)]
head = "%-8s" % "档" + "".join("%10s" % ("c=%d" % b[0] if b[1]-b[0] <= 1 else "c=%d-%d" % b) for b in buckets)
print(head)


def median(xs):
    if not xs:
        return 0
    xs = sorted(xs)
    return xs[len(xs) // 2]


tab = {}
for t in ["intro", "easy", "normal", "hard"]:
    row = [0] * len(buckets)
    for l in levels:
        if tier_ours(l["difficulty"]) != t:
            continue
        for i, (lo, hi) in enumerate(buckets):
            if lo <= l["max_complexity"] <= hi:
                row[i] += 1
                break
    tab[t] = row
    tot = sum(row) or 1
    med = median([l["max_complexity"] for l in levels if tier_ours(l["difficulty"]) == t])
    print("%-8s" % t + "".join("%9d " % v for v in row) + " (n=%d, 中位 c=%d)" % (tot, med))

# ── 3) 秩相关 ──
pairs = [(l["difficulty"], l["max_complexity"]) for l in levels]
print("\n[3] 秩相关 Spearman(difficulty, max_complexity) = %.3f" % spearman(pairs))
for W in (3, 15):
    pairs2 = [(l["difficulty"], rank_score(l["hist"], W)) for l in levels if l["hist"]]
    print("    Spearman(difficulty, RankScore[W=%d]) = %.3f  （n=%d）" % (W, spearman(pairs2), len(pairs2)))

# ── 4) 用对方政策回判：我们的 hard 盘，在对方体系里算什么 ──
print("\n[4] 对方政策回判（MIN_COMPLEXITY_NIGHTMARE：5×5/6×6=5，7×7+=6）：")
for t in ["intro", "easy", "normal", "hard"]:
    sub = [l for l in levels if tier_ours(l["difficulty"]) == t and l["size"] in (5,6,7,8,9)]
    if not sub: continue
    reach = sum(1 for l in sub if l["max_complexity"] >= MIN.get(l["size"], 6))
    print("    我们的 %-6s：%6d 关 → 达到对方「噩梦 MIN」的 %6d 关（%.1f%%）" % (t, len(sub), reach, 100.0*reach/len(sub)))

# ── 5) 若改用对方峰值度量，档位会怎么变（按对方三档 MIN：普通2/困难4/噩梦5-6）──
print("\n[5] 若以对方峰值复判三档（普通 c>=2 / 困难 c>=4 / 噩梦 c>=5-6）：")
b_by_tier = collections.Counter()
for l in levels:
    c, sz = l["max_complexity"], l["size"]
    if c >= MIN.get(sz, 6): b_by_tier["噩梦"] += 1
    elif c >= 4: b_by_tier["困难"] += 1
    elif c >= 2: b_by_tier["普通"] += 1
    else: b_by_tier["不达标"] += 1
print("    %s" % dict(b_by_tier))
print("    ≈ 全样本的 %.1f%% 连对方「普通」门槛都够不到（c<2）" % (100.0*b_by_tier["不达标"]/N))

# ── 6) RankScore 与 difficulty 的排序分歧（前 100 名重合度）──
print("\n[6] 排序分歧：各自按 difficulty / RankScore 取前 100，重合度")
top_d = {id(l) for l in sorted(levels, key=lambda x: -x["difficulty"])[:100]}
for W in (3, 15):
    cand = [l for l in levels if l["hist"]]
    top_r = {id(l) for l in sorted(cand, key=lambda x: -rank_score(x["hist"], W))[:100]}
    print("    Top100 重合：difficulty vs RankScore[W=%d] = %d/100（%d%%）" % (W, len(top_d & top_r), len(top_d & top_r)))
