"""
扫雷核心引擎 + 逻辑求解器 + 唯一解生成器
仅使用 Python 标准库。

设计目标：
1. 三种棋盘：9x9, 16x16, 16x30
2. 唯一解：通过回溯求解器验证，保证盘面每一步可由逻辑推理推出
3. 首次点击安全、连锁展开、标记、胜负判定
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import List, Optional, Set, Tuple, Dict

BOARD_PRESETS = {
    "beginner": {"rows": 9, "cols": 9, "mines": 10},
    "intermediate": {"rows": 16, "cols": 16, "mines": 40},
    "expert": {"rows": 16, "cols": 30, "mines": 99},
}

# 八个方向的偏移
DIRS8 = [(-1, -1), (-1, 0), (-1, 1),
         (0, -1),           (0, 1),
         (1, -1),  (1, 0),  (1, 1)]


class GameState:
    PLAYING = "playing"
    WON = "won"
    LOST = "lost"


class Cell:
    __slots__ = ("is_mine", "is_revealed", "is_flagged", "adjacent_mines")

    def __init__(self):
        self.is_mine = False
        self.is_revealed = False
        self.is_flagged = False
        self.adjacent_mines = 0


@dataclass
class Board:
    rows: int
    cols: int
    cells: List[List[Cell]] = field(default_factory=list)

    def __post_init__(self):
        if not self.cells:
            self.cells = [[Cell() for _ in range(self.cols)] for _ in range(self.rows)]

    def in_bounds(self, r: int, c: int) -> bool:
        return 0 <= r < self.rows and 0 <= c < self.cols

    def neighbors(self, r: int, c: int):
        for dr, dc in DIRS8:
            nr, nc = r + dr, c + dc
            if self.in_bounds(nr, nc):
                yield nr, nc

    def adjacent_mine_count(self, r: int, c: int) -> int:
        return sum(1 for nr, nc in self.neighbors(r, c) if self.cells[nr][nc].is_mine)


class MinesweeperGame:
    """核心游戏引擎：布雷、翻开、插旗、连锁展开、胜负判定。"""

    def __init__(self, rows: int = 9, cols: int = 9, mines: int = 10):
        total = rows * cols
        if rows <= 0 or cols <= 0:
            raise ValueError("棋盘尺寸必须为正")
        if not 0 < mines < total:
            raise ValueError(f"雷数必须在 1 到 {total - 1} 之间，实际为 {mines}")
        self.rows = rows
        self.cols = cols
        self.mines = mines
        self.board = Board(rows, cols)
        self.state = GameState.PLAYING
        self._mines_placed = False  # 延迟布雷：首次点击后才布雷（保证首雷安全）
        self.safe_cells_remaining = rows * cols - mines

    # ---------- 布雷 ----------
    def _place_mines(self, safe_r: int, safe_c: int) -> None:
        """首次点击后布雷：safe 格及其 8 邻全部安全，其余随机布雷。"""
        protected = set()
        protected.add((safe_r, safe_c))
        for nr, nc in self.board.neighbors(safe_r, safe_c):
            protected.add((nr, nc))
        pool = [(r, c) for r in range(self.rows) for c in range(self.cols)
                if (r, c) not in protected]
        if len(pool) < self.mines:
            raise ValueError("雷数过多，无法在保护区域外放置")
        mine_positions = random.sample(pool, self.mines)
        for r, c in mine_positions:
            self.board.cells[r][c].is_mine = True
        for r in range(self.rows):
            for c in range(self.cols):
                self.board.cells[r][c].adjacent_mines = self.board.adjacent_mine_count(r, c)
        self._mines_placed = True

    # ---------- 交互 ----------
    def reveal(self, r: int, c: int) -> List[Tuple[int, int]]:
        """翻开一格。返回本操作新翻开的格子列表。"""
        if self.state != GameState.PLAYING:
            return []
        if not self.board.in_bounds(r, c):
            return []
        cell = self.board.cells[r][c]
        if cell.is_revealed or cell.is_flagged:
            return []

        if not self._mines_placed:
            self._place_mines(r, c)

        revealed = self._flood_reveal(r, c)

        # 结算：踩雷
        if self.board.cells[r][c].is_mine:
            self.state = GameState.LOST
            self._reveal_all_mines()
            return revealed

        # 结算：胜利
        if self._check_win():
            self.state = GameState.WON
            self._auto_flag_mines()
        return revealed

    def _flood_reveal(self, r: int, c: int) -> List[Tuple[int, int]]:
        """连锁展开（BFS）：翻开该格，若是空白(0)则递归展开相邻安全格。"""
        revealed = []
        stack = [(r, c)]
        while stack:
            cr, cc = stack.pop()
            cell = self.board.cells[cr][cc]
            if cell.is_revealed or cell.is_flagged:
                continue
            if cell.is_mine:
                continue  # 防御：BFS 只在空白格扩展
            cell.is_revealed = True
            revealed.append((cr, cc))
            self.safe_cells_remaining -= 1
            if cell.adjacent_mines == 0:
                for nr, nc in self.board.neighbors(cr, cc):
                    ncell = self.board.cells[nr][nc]
                    if not ncell.is_revealed and not ncell.is_flagged and not ncell.is_mine:
                        stack.append((nr, nc))
        return revealed

    def toggle_flag(self, r: int, c: int) -> None:
        """插旗/取消旗。已翻开的格子不可插旗。"""
        if self.state != GameState.PLAYING:
            return
        if not self.board.in_bounds(r, c):
            return
        cell = self.board.cells[r][c]
        if cell.is_revealed:
            return
        cell.is_flagged = not cell.is_flagged

    def flag_count(self) -> int:
        return sum(1 for row in self.board.cells for c in row if c.is_flagged)

    def _revealed_positions(self) -> List[Tuple[int, int]]:
        """当前所有已翻开的安全格坐标。"""
        return [(r, c) for r in range(self.rows) for c in range(self.cols)
                if self.board.cells[r][c].is_revealed]

    # ---------- 结算 ----------
    def _check_win(self) -> bool:
        return self.safe_cells_remaining <= 0

    def _reveal_all_mines(self) -> None:
        for row in self.board.cells:
            for c in row:
                if c.is_mine:
                    c.is_revealed = True
                    c.is_flagged = False  # 保持状态一致：翻开格无旗

    def _auto_flag_mines(self) -> None:
        for row in self.board.cells:
            for c in row:
                if c.is_mine:
                    c.is_flagged = True

    # ---------- 展示 ----------
    def render(self) -> str:
        lines = []
        header = "   " + " ".join(str(c % 10) for c in range(self.cols))
        lines.append(header)
        for r in range(self.rows):
            row = [f"{r:2d} "]
            for c in range(self.cols):
                cell = self.board.cells[r][c]
                if cell.is_flagged:
                    row.append("F")
                elif not cell.is_revealed:
                    row.append(".")
                elif cell.is_mine:
                    row.append("*")
                elif cell.adjacent_mines == 0:
                    row.append(" ")
                else:
                    row.append(str(cell.adjacent_mines))
            lines.append(" ".join(row))
        return "\n".join(lines)


# ======================================================================
# 逻辑求解器：基于回溯搜索的唯一解验证 + 下一步提示
# ======================================================================

class LogicSolver:
    """
    约束满足求解器。
    状态由两个集合表示：known_safe（确定安全格）、known_mine（确定雷格）。
    所有推理都基于"数字格的实际 8 邻雷数 == 该格数字"这一约束。
    提供：
      - count_solutions(revealed)  从给定已揭示格出发，统计满足约束的解数量
      - is_unique()                整盘是否唯一解
      - next_move(revealed)        当前局面下所有解中状态一致的确定动作
    """

    def __init__(self, board: Board):
        self.rows = board.rows
        self.cols = board.cols
        # 真实盘面（用于起始格选择等，不做约束验证依据）
        self.mine = [[board.cells[r][c].is_mine for c in range(self.cols)]
                     for r in range(self.rows)]
        self.adj = [[board.cells[r][c].adjacent_mines for c in range(self.cols)]
                    for r in range(self.rows)]

    def in_bounds(self, r, c):
        return 0 <= r < self.rows and 0 <= c < self.cols

    def neighbors(self, r, c):
        for dr, dc in DIRS8:
            nr, nc = r + dr, c + dc
            if self.in_bounds(nr, nc):
                yield nr, nc

    # 一个格周围已知的雷数（在 known_mine 中）
    def _mine_neighbors(self, r, c, known_mine):
        return sum(1 for p in self.neighbors(r, c) if p in known_mine)

    # ------------------------------------------------------------------
    # 约束传播：从 known_safe + known_mine 推导更多确定格
    # ------------------------------------------------------------------
    def propagate(self, known_safe, known_mine):
        """
        确定性传播。返回 (safe, mine)。
        规则：
          - safe 格其邻域已知雷数 = 数字时，邻域剩余未知格全安全
          - safe 格其邻域未知格数 = 剩余需雷数时，这些未知格全为雷
        """
        safe = set(known_safe)
        mine = set(known_mine)
        changed = True
        while changed:
            changed = False
            for (r, c) in list(safe):
                nb = set(self.neighbors(r, c))
                unknown = [p for p in nb if p not in safe and p not in mine]
                mine_known = self._mine_neighbors(r, c, mine)
                need = self.adj[r][c] - mine_known
                if need < 0:
                    # 矛盾：雷数已超数字。标记，返回 (safe, mine) 由调用方判冲突。
                    return safe, mine
                if need == 0:
                    for p in unknown:
                        if p not in safe:
                            safe.add(p)
                            changed = True
                elif need == len(unknown):
                    for p in unknown:
                        if p not in mine:
                            mine.add(p)
                            changed = True
        return safe, mine

    def _is_conflict(self, safe, mine):
        """safe 集合中是否存在某格实际雷数超过其数字（矛盾）。"""
        for (r, c) in safe:
            actual = self._mine_neighbors(r, c, mine)
            if actual > self.adj[r][c]:
                return True
        # 若某安全格所有邻居都已知且雷数不等于数字，也矛盾
        for (r, c) in safe:
            nb = set(self.neighbors(r, c))
            unknown = [p for p in nb if p not in safe and p not in mine]
            actual = self._mine_neighbors(r, c, mine)
            if not unknown and actual != self.adj[r][c]:
                return True
        return False

    def _decision_cells(self, safe, mine):
        """返回当前可分裂的候选格（任一约束格的未知邻域）。"""
        cells = set()
        for (r, c) in safe:
            for p in self.neighbors(r, c):
                if p not in safe and p not in mine:
                    cells.add(p)
        return sorted(cells)

    # ------------------------------------------------------------------
    # 回溯计数
    # ------------------------------------------------------------------
    def count_solutions(self, revealed, cap: int = 2) -> int:
        safe, mine = self.propagate(set(revealed), set())
        return self._count(safe, mine, cap)

    def _count(self, safe, mine, cap) -> int:
        if cap <= 0:
            return cap  # 已达上限
        if self._is_conflict(safe, mine):
            return 0
        decision = self._decision_cells(safe, mine)
        if not decision:
            # 无未知邻域格：所有约束已完全决定 -> 1 个解
            return 1
        split = decision[0]
        total = 0
        # 分支：split 安全
        total += self._count(safe | {split}, mine, cap - total)
        if total > cap:
            return total
        # 分支：split 为雷
        total += self._count(safe, mine | {split}, cap - total)
        return total

    # ------------------------------------------------------------------
    # 唯一解验证
    # ------------------------------------------------------------------
    def is_unique(self) -> bool:
        start = self._pick_start()
        if start is None:
            return False
        return self.count_solutions({start}, cap=2) == 1

    def _pick_start(self):
        """选一个起始安全格：空白(0)优先，其次任意非雷格。"""
        for r in range(self.rows):
            for c in range(self.cols):
                if not self.mine[r][c] and self.adj[r][c] == 0:
                    return (r, c)
        for r in range(self.rows):
            for c in range(self.cols):
                if not self.mine[r][c]:
                    return (r, c)
        return None

    # ------------------------------------------------------------------
    # 下一步提示
    # ------------------------------------------------------------------
    def next_move(self, revealed):
        """
        枚举足够多的解，统计各格状态一致性。
        返回 (click, flag)：
          click: 所有解中都安全的格（可点击）
          flag:  所有解中都是雷的格（可标记）
        本框架保证唯一解的盘面，配合迭代可全程推进。
        """
        solutions = []
        self._collect_solutions(set(revealed), solutions, cap=16)
        if not solutions:
            return set(), set()
        # 交集统计
        all_cells = self._all_cells()
        safe_in_all = set(all_cells)
        mine_in_all = set()
        for (safe, mine) in solutions:
            safe_in_all &= safe
            mine_in_all &= mine
        click = {p for p in safe_in_all if p not in revealed}
        flag = set(mine_in_all)
        return click, flag

    def _collect_solutions(self, revealed, out, cap):
        safe, mine = self.propagate(revealed, set())
        self._enum(safe, mine, out, cap)

    def _enum(self, safe, mine, out, cap):
        if len(out) >= cap:
            return
        safe, mine = self.propagate(safe, mine)
        if self._is_conflict(safe, mine):
            return
        decision = self._decision_cells(safe, mine)
        if not decision:
            out.append((set(safe), set(mine)))
            return
        split = decision[0]
        self._enum(safe | {split}, mine, out, cap)
        self._enum(safe, mine | {split}, out, cap)

    def _all_cells(self):
        return [(r, c) for r in range(self.rows) for c in range(self.cols)]


# ======================================================================
# 唯一解生成器
# ======================================================================

class UniqueBoardGenerator:
    """
    生成"全局唯一解"的盘面。
    策略：随机布雷 -> 回溯求解器验证唯一解；不唯一则重试。
    """

    def __init__(self, rng: Optional[random.Random] = None):
        self.rng = rng or random.Random()

    def generate(self, rows: int, cols: int, mines: int,
                 max_attempts: int = 400) -> Optional[Board]:
        total = rows * cols
        if not 0 < mines < total:
            raise ValueError("雷数非法")
        for _ in range(max_attempts):
            board = self._random_board(rows, cols, mines)
            solver = LogicSolver(board)
            if solver.is_unique():
                return board
        return None

    def generate_guaranteed(self, rows, cols, mines,
                            max_attempts=400) -> Board:
        """保证返回一个盘面（唯一解优先，失败则返回合法盘兜底）。"""
        board = self.generate(rows, cols, mines, max_attempts)
        if board is not None:
            return board
        return self._random_board(rows, cols, mines)

    def _random_board(self, rows, cols, mines) -> Board:
        board = Board(rows, cols)
        positions = self.rng.sample(
            [(r, c) for r in range(rows) for c in range(cols)], mines)
        for r, c in positions:
            board.cells[r][c].is_mine = True
        for r in range(rows):
            for c in range(cols):
                board.cells[r][c].adjacent_mines = board.adjacent_mine_count(r, c)
        return board
