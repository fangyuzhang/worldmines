# verify.py —— Spike B（Python 侧）：z3 编码器校验 + 唯一性关系分析
#
# 【重要 · plan1.9 修订】
#   本脚本【不再】校验「可解 ⟹ 唯一」——该蕴含已被 Spike B 实测证伪
#   （3×3 全穷举：130 个成功局中 49 个 S* 多解、104 个初始多解）。
#   「success 且多解」是【预期结果】，不是失败，退出码不因此非零。
#   soundness 的正确检验口径是「逐步 Oracle 包含性」，见
#   res://spike/spike_b_soundness.gd（实测 844 断言 / 0 违例）。
#
# 当前用途：
#   1) 【唯一硬失败项】编码正确性：z3 解数 == 独立穷举解数
#      （不一致 = S* 编码器有 bug = 可用于生产的编码器不可信）
#   2) 关系分析：simulate 成功/失败 × (S* 唯一 / 初始唯一) 的列联表
#      —— 量化两种「唯一性」与「纯逻辑可解」的真实关系（实测：互不包含）
#   3) L3 缺口：S* 唯一但 L0/L1/L2 不可解的用例数（L3 增量上界）
#
# 用法：
#   python tools/certify/verify.py [--json <path>] [--cap N]
# 默认读取： %APPDATA%/Godot/app_userdata/世界扫雷/spike_b_sim.json

import argparse
import itertools
import json
import os
import sys

# Windows 控制台默认 GBK，中文之外的符号会抛 UnicodeEncodeError
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

try:
    from z3 import And, Bool, If, Implies, Not, Solver, Sum, sat
except ImportError:
    print("FATAL: 需要 z3-solver。安装： python -m pip install z3-solver")
    sys.exit(2)


# ───────────────────────── 几何与线索（独立于 GDScript 重算） ─────────────────────────

def neighbors(r, c, rows, cols):
    for dr in (-1, 0, 1):
        for dc in (-1, 0, 1):
            if dr == 0 and dc == 0:
                continue
            nr, nc = r + dr, c + dc
            if 0 <= nr < rows and 0 <= nc < cols:
                yield (nr, nc)


def compute_clues(mines, rows, cols):
    """引擎语义（board.gd._compute_clues）：雷格无线索（不产生约束），
    非雷格线索值 = 8 邻雷数。"""
    ms = set(mines)
    clues = {}
    for r in range(rows):
        for c in range(cols):
            if (r, c) in ms:
                continue
            clues[(r, c)] = sum(1 for n in neighbors(r, c, rows, cols) if n in ms)
    return clues


# ───────────────────────── S* 解数统计 ─────────────────────────

def count_solutions_z3(mines, rows, cols, M, cap=2):
    """S* = { Σ mine = M } ∪ { ¬mine[p] ⟹ nbcount(p) == clue(p) | p 为真解的非雷格 }
    返回：0=矛盾 1=唯一 >=cap=多解（cap 提前终止）"""
    cells = [(r, c) for r in range(rows) for c in range(cols)]
    mv = {p: Bool("m_%d_%d" % p) for p in cells}
    clues = compute_clues(mines, rows, cols)

    s = Solver()
    s.add(Sum([If(mv[p], 1, 0) for p in cells]) == M)
    for p, v in clues.items():
        nb = [mv[n] for n in neighbors(p[0], p[1], rows, cols)]
        if nb:
            s.add(Implies(Not(mv[p]), Sum([If(x, 1, 0) for x in nb]) == v))
        else:
            s.add(Implies(Not(mv[p]), v == 0))

    n = 0
    while n < cap and s.check() == sat:
        model = s.model()
        block = []
        for p in cells:
            val = model.eval(mv[p], model_completion=True)
            block.append(mv[p] == val)
        s.add(Not(And(block)))
        n += 1
    return n


def count_solutions_init(mines, rows, cols, M, s0, cap=2):
    """初始约束集（plan1.3 §3.2 原口径）：S0 安全 + S0 线索值。
    仅用开局那一格的信息 ⇒ 解集通常很大。"""
    cells = [(r, c) for r in range(rows) for c in range(cols)]
    s0 = tuple(s0)
    clue0 = sum(1 for n in neighbors(s0[0], s0[1], rows, cols) if n in set(mines))
    n = 0
    for combo in itertools.combinations(cells, M):
        cand = set(combo)
        if s0 in cand:
            continue
        if sum(1 for x in neighbors(s0[0], s0[1], rows, cols) if x in cand) != clue0:
            continue
        n += 1
        if n >= cap:
            break
    return n


def count_solutions_exhaustive(mines, rows, cols, M, cap=2):
    """纯 Python 穷举（3×3 规模的独立基准，不依赖 z3）。"""
    cells = [(r, c) for r in range(rows) for c in range(cols)]
    clues = compute_clues(mines, rows, cols)
    n = 0
    for combo in itertools.combinations(cells, M):
        cand = set(combo)
        ok = True
        for p, v in clues.items():
            if p in cand:
                continue            # 候选里 p 是雷 ⇒ 该格不显示线索 ⇒ 约束不适用
            if sum(1 for x in neighbors(p[0], p[1], rows, cols) if x in cand) != v:
                ok = False
                break
        if ok:
            n += 1
            if n >= cap:
                break
    return n


# ───────────────────────── 主流程 ─────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default=None, help="GDScript 导出的 sim 结果路径")
    ap.add_argument("--cap", type=int, default=2, help="唯一性判定的解数上限")
    args = ap.parse_args()

    path = args.json
    if path is None:
        appdata = os.environ.get("APPDATA", "")
        path = os.path.join(appdata, "Godot", "app_userdata", "世界扫雷", "spike_b_sim.json")
    if not os.path.exists(path):
        print("FATAL: 找不到 %s" % path)
        sys.exit(2)

    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    rows = data["grid"]["rows"]
    cols = data["grid"]["cols"]
    cases = data["cases"]

    # 1) 按布局去重，统计 S* 解数（z3 + 穷举）
    layout_info = {}
    for case in cases:
        key = tuple(sorted(tuple(m) for m in case["mines"]))
        if key in layout_info:
            continue
        M = case["mine_count"]
        nz = count_solutions_z3(list(key), rows, cols, M, args.cap)
        ne = count_solutions_exhaustive(list(key), rows, cols, M, args.cap)
        layout_info[key] = {"z3": nz, "exh": ne, "M": M}

    # 2) 编码器正确性 + 蕴含定理
    encode_mismatch = []
    violations = []
    stats = {
        "cases": len(cases),
        "layouts": len(layout_info),
        "success_cases": 0,
        "unique_layouts": 0,
        "multi_layouts": 0,
        "contradiction_layouts": 0,
        "l3_gap_cases": 0,      # S* 唯一 但 simulate 失败
        # 2×2 列联表：success × (S* 唯一 / 初始唯一)
        "ok_and_sstar_unique": 0,
        "ok_and_sstar_multi": 0,
        "ok_and_init_unique": 0,
        "ok_and_init_multi": 0,
        "fail_and_sstar_unique": 0,
        "fail_and_sstar_multi": 0,
        "fail_and_init_unique": 0,
        "fail_and_init_multi": 0,
        "init_unique_cases": 0,
    }

    for case in cases:
        key = tuple(sorted(tuple(m) for m in case["mines"]))
        info = layout_info[key]
        nz, ne = info["z3"], info["exh"]

        if nz != ne:
            encode_mismatch.append({
                "mines": list(key), "M": info["M"], "z3": nz, "exhaustive": ne,
            })

        sstar_unique = (nz == 1)
        n_init = count_solutions_init(list(key), rows, cols, info["M"], case["s0"], args.cap)
        init_unique = (n_init == 1)
        if init_unique:
            stats["init_unique_cases"] += 1

        ok = bool(case["success"])
        if ok:
            stats["success_cases"] += 1
            if sstar_unique:
                stats["ok_and_sstar_unique"] += 1
            else:
                stats["ok_and_sstar_multi"] += 1
                violations.append({
                    "case_id": case["case_id"],
                    "mines": list(key), "M": info["M"], "s0": case["s0"],
                    "z3_solutions": nz, "exhaustive_solutions": ne,
                    "revealed": case.get("revealed"), "target": case.get("target"),
                })
            if init_unique:
                stats["ok_and_init_unique"] += 1
            else:
                stats["ok_and_init_multi"] += 1
        else:
            if sstar_unique:
                stats["fail_and_sstar_unique"] += 1
                stats["l3_gap_cases"] += 1
            else:
                stats["fail_and_sstar_multi"] += 1
            if init_unique:
                stats["fail_and_init_unique"] += 1
            else:
                stats["fail_and_init_multi"] += 1

    for k, info in layout_info.items():
        if info["z3"] == 1:
            stats["unique_layouts"] += 1
        elif info["z3"] == 0:
            stats["contradiction_layouts"] += 1
        else:
            stats["multi_layouts"] += 1

    # 3) 报告
    print("=== Spike B : z3 交叉验证（蕴含定理校验） ===")
    print("用例 %d / 布局 %d / 网格 %dx%d" % (stats["cases"], stats["layouts"], rows, cols))
    print("S* 解数分布： 唯一=%d  多解=%d  矛盾=%d"
          % (stats["unique_layouts"], stats["multi_layouts"], stats["contradiction_layouts"]))
    print("编码器交叉校验（z3 vs 穷举）： %s  不一致 %d 处"
          % ("OK" if not encode_mismatch else "*** FAIL ***", len(encode_mismatch)))
    for e in encode_mismatch[:5]:
        print("   MISMATCH mines=%s M=%d z3=%d exh=%d" % (e["mines"], e["M"], e["z3"], e["exhaustive"]))
    print("【关系分析】success 且 S* 多解： %d / %d 成功局   （预期存在，非失败）"
          % (len(violations), stats["success_cases"]))
    for v in violations[:3]:
        print("   样例 %s mines=%s M=%d s0=%s z3=%d exh=%d revealed=%s/%s"
              % (v["case_id"], v["mines"], v["M"], v["s0"], v["z3_solutions"],
                 v["exhaustive_solutions"], v["revealed"], v["target"]))
    print("L3 缺口（S* 唯一但 L0/L1/L2 不可解的用例）： %d / %d"
          % (stats["l3_gap_cases"], stats["cases"] - stats["success_cases"]))
    print("simulate 成功 %d / 失败 %d ；初始唯一 %d"
          % (stats["success_cases"], stats["cases"] - stats["success_cases"],
             stats["init_unique_cases"]))
    print("列联表  success × S*唯一 ： %d / %d   （右下 = 蕴含定理违例）"
          % (stats["ok_and_sstar_unique"], stats["ok_and_sstar_multi"]))
    print("列联表  success × 初始唯一： %d / %d"
          % (stats["ok_and_init_unique"], stats["ok_and_init_multi"]))
    print("列联表  fail    × 初始唯一： %d / %d   （左上 = 初始唯一但需猜）"
          % (stats["fail_and_init_unique"], stats["fail_and_init_multi"]))

    out_path = os.path.join(os.path.dirname(path), "spike_b_verify.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({
            "suite": "spike_b", "spec": "plan1.8 §2.3",
            "stats": stats,
            "encode_mismatch_count": len(encode_mismatch),
            "violation_count": len(violations),
            "encode_mismatch_sample": encode_mismatch[:20],
            "violations_sample": violations[:20],
        }, f, ensure_ascii=False, indent=2)
    print("结果 -> %s" % out_path)

    # plan1.9：唯一硬失败项 = 编码器不一致；「success 且多解」是预期，不判失败
    if encode_mismatch:
        print("=== Spike B FAIL：z3 编码器与独立穷举不一致 ===")
        sys.exit(1)
    print("=== Spike B PASS（编码器正确；关系数据见上） ===")


if __name__ == "__main__":
    main()
