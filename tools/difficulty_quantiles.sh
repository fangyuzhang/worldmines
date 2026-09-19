#!/bin/bash
# 服务器侧全席难度分位标定 v2：自动探测 user:// 产物目录
echo "=== 探测 batch_* 目录 ==="
CAND=$(find /root/.local /root -maxdepth 9 -type d -name "batch_*" 2>/dev/null | head -40)
echo "$CAND" | head -8
echo "___ COUNT=$(echo "$CAND" | grep -c . )"

python3 - <<'PY'
import json, glob, os, collections

def q(xs, p):
    if not xs: return 0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, max(0, int(round(p * (len(xs) - 1)))))]

# 找所有 batch_* 目录
bdirs = []
for base in ("/root/.local", "/root"):
    for dirpath, dirnames, _ in os.walk(base):
        for d in list(dirnames):
            if d.startswith("batch_"):
                bdirs.append(os.path.join(dirpath, d))
        if len(dirpath.split(os.sep)) > 12: dirnames[:] = []
print("batch 目录数：%d" % len(bdirs))
if bdirs:
    print("样例：%s" % bdirs[0])

cells = collections.defaultdict(list)
nf = 0
for b in bdirs:
    var = os.path.basename(b)
    for f in glob.glob(b + "/**/*.json", recursive=True):
        if "report" in os.path.basename(f): continue
        try: j = json.load(open(f, encoding="utf-8"))
        except Exception: continue
        if not isinstance(j, dict) or "difficulty_profile" not in j: continue
        nf += 1
        dp = j["difficulty_profile"]
        size = int((j.get("size") or {}).get("cols", 0) or 0)
        cells[(var, size)].append(int(dp.get("max_complexity", 0) or 0))

print("解析关卡数：%d  单元数：%d" % (nf, len(cells)))
if not cells:
    raise SystemExit("未找到关卡 JSON")

print("%-18s %-3s %6s %5s %5s %5s %5s %5s" % ("批次(变体)", "尺寸", "n", "P40", "P70", "P90", "P95", "MAX"))
allpk = []
for (var, size) in sorted(cells):
    pk = cells[(var, size)]; allpk += pk
    if len(pk) < 60: continue
    print("%-18s %-3d %6d %5d %5d %5d %5d %5d" % (var, size, len(pk), q(pk,.40), q(pk,.70), q(pk,.90), q(pk,.95), max(pk)))
print("\n全局分位：P40=%d P70=%d P90=%d P95=%d MAX=%d（n=%d）" % (
    q(allpk,.40), q(allpk,.70), q(allpk,.90), q(allpk,.95), max(allpk), len(allpk)))
deg = [("%s@%d" % (v, s)) for (v, s), pk in cells.items() if len(pk) >= 60 and q(pk, .90) <= 1]
print("退化单元（P90<=1）：%d 个 → %s" % (len(deg), ", ".join(sorted(deg)[:24])))
rich = [("%s@%d" % (v, s)) for (v, s), pk in cells.items() if len(pk) >= 60 and q(pk, .90) >= 8]
print("高深单元（P90>=8）：%d 个 → %s" % (len(rich), ", ".join(sorted(rich)[:24])))
PY
