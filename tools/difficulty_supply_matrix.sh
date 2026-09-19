#!/bin/bash
# 离线重标：把现有全部产物按「绝对深度窗口」重算档位 → 真实供给矩阵（零生成成本）
python3 - <<'PY'
import json, glob, os, collections

def q(xs, p):
    if not xs: return 0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, max(0, int(round(p * (len(xs) - 1)))))]

# 绝对窗口草案（全局统一，跨变体/尺寸可比）
WIN = [("入门", lambda c: c <= 2),
       ("正常", lambda c: 3 <= c <= 4),
       ("困难", lambda c: 5 <= c <= 8),
       ("噩梦", lambda c: 9 <= c <= 20),
       ("超纲", lambda c: c >= 21)]

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
        dp = j["difficulty_profile"]
        hist = {}
        for part in str(dp.get("histogram", "")).split(","):
            part = part.strip()
            if "x" in part:
                a, bb = part.split("x", 1)
                try: hist[int(a)] = int(bb)
                except ValueError: pass
        cells[(var, int((j.get("size") or {}).get("cols", 0) or 0))].append({
            "peak": int(dp.get("max_complexity", 0) or 0),
            "steps": sum(hist.values()),
            "diff": float(dp.get("difficulty", 0.0)),
        })

# 1) 供给矩阵
print("=== 供给矩阵（峰值窗口 → 现有关卡数）===")
print("%-20s %-3s %6s %6s %6s %6s %6s %6s %8s" % ("批次(变体)", "尺寸", "总数", "入门<=2", "正常3-4", "困难5-8", "噩梦9+", "超纲21+", "均步数"))
tot = collections.Counter()
allpk = []
for (var, size) in sorted(cells):
    sub = cells[(var, size)]
    if len(sub) < 60: continue
    cnt = collections.Counter()
    for l in sub:
        allpk.append(l["peak"])
        for name, f in WIN:
            if f(l["peak"]): cnt[name] += 1; break
    tot.update(cnt)
    print("%-20s %-3d %6d %6d %6d %6d %6d %6d %8.1f" % (
        var, size, len(sub), cnt["入门"], cnt["正常"], cnt["困难"], cnt["噩梦"], cnt["超纲"],
        sum(l["steps"] for l in sub) / len(sub)))
print("%-20s %-3s %6d %6d %6d %6d %6d %6d" % ("【合计】", "", sum(tot.values()), tot["入门"], tot["正常"], tot["困难"], tot["噩梦"], tot["超纲"]))

# 2) 单元级判定：能否供给 4 档（每档需 >=100 关才有意义组一集）
print("\n=== 单元供给能力（每格每档是否有 ≥100 关）===")
ok = missing = 0
lack = []
for (var, size) in sorted(cells):
    sub = cells[(var, size)]
    if len(sub) < 60: continue
    have = {n: sum(1 for l in sub if f(l["peak"])) for n, f in WIN}
    miss = [n for n in ("入门", "正常", "困难", "噩梦") if have[n] < 100]
    if miss:
        missing += 1; lack.append("%s@%d 缺[%s]" % (var, size, ",".join(miss)))
    else:
        ok += 1
print("四档齐备的单元：%d；有缺口的单元：%d" % (ok, missing))
for x in lack[:18]: print("  ✗ %s" % x)

# 3) 建议：缺口靠尺寸或排序补，还是禁止该档
print("\n=== 结论要点 ===")
print("全局峰值分位：P40=%d P70=%d P90=%d P95=%d MAX=%d（n=%d）" % (
    q(allpk,.40), q(allpk,.70), q(allpk,.90), q(allpk,.95), max(allpk), len(allpk)))
print("窗口占比：入门 %.1f%% / 正常 %.1f%% / 困难 %.1f%% / 噩梦 %.1f%% / 超纲 %.1f%%" % tuple(
    100.0 * tot[k] / max(1, sum(tot.values())) for k in ("入门", "正常", "困难", "噩梦", "超纲")))
PY
