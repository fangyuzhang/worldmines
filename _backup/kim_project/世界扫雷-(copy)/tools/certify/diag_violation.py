# diag_violation.py —— 核验 Spike B 的首个违例案例（3 种唯一性口径对照）
import itertools

ROWS, COLS = 3, 3
CELLS = [(r, c) for r in range(ROWS) for c in range(COLS)]


def nb(p):
    r, c = p
    out = []
    for dr in (-1, 0, 1):
        for dc in (-1, 0, 1):
            if dr == 0 and dc == 0:
                continue
            nr, nc = r + dr, c + dc
            if 0 <= nr < ROWS and 0 <= nc < COLS:
                out.append((nr, nc))
    return out


MINES = {(0, 0), (0, 1), (0, 2)}
M = 3
S0 = (2, 0)
clue = lambda p: sum(1 for n in nb(p) if n in MINES)
NONMINES = [p for p in CELLS if p not in MINES]

print("true clues:", {p: clue(p) for p in NONMINES})

# A) 初始约束集：S0 安全 + S0 线索
solsA = []
for combo in itertools.combinations(CELLS, M):
    cand = set(combo)
    if S0 in cand:
        continue
    if sum(1 for n in nb(S0) if n in cand) != clue(S0):
        continue
    solsA.append(sorted(cand))
print("A) 初始约束集解数 =", len(solsA))

# B) S* 完全信息（条件式：真解非雷格 => 线索值）
solsB = []
for combo in itertools.combinations(CELLS, M):
    cand = set(combo)
    if all((p in cand) or (sum(1 for n in nb(p) if n in cand) == clue(p)) for p in NONMINES):
        solsB.append(sorted(cand))
print("B) S* 完全信息解数 =", len(solsB))
for s in solsB:
    print("     ", s, "<-- 真解" if set(s) == MINES else "")

# C) S* + 已翻开事实（pin 真解非雷格为非雷）
solsC = [s for s in solsB if set(s) == MINES]
print("C) S* + pin 解数 =", len(solsC))
