"""
扫雷演示：三种棋盘 + 唯一解生成 + 求解器引导对局 + 界面渲染
运行: python demo.py
"""
from __future__ import annotations

import random
from minesweeper import (
    BOARD_PRESETS, MinesweeperGame, GameState,
    UniqueBoardGenerator, LogicSolver, Board,
)


def _game_from_board(board: Board) -> MinesweeperGame:
    mine_count = sum(1 for row in board.cells for c in row if c.is_mine)
    g = MinesweeperGame(board.rows, board.cols, mine_count)
    g.board = board
    g._mines_placed = True
    g.safe_cells_remaining = g.rows * g.cols - g.mines
    g.state = GameState.PLAYING
    return g


def demo_solver_play(name, rows, cols, mines, seed):
    print("=" * 70)
    print(f"[{name}] {rows}x{cols} / {mines} 雷 (seed={seed})")
    gen = UniqueBoardGenerator(random.Random(seed))
    board = gen.generate(rows, cols, mines, max_attempts=300)
    if board is None:
        print("  未能生成唯一解盘（尝试次数内）")
        return
    solver = LogicSolver(board)
    unique = solver.is_unique()
    print(f"  唯一解验证: {'通过' if unique else '未通过'}")
    g = _game_from_board(board)
    start = solver._pick_start()
    if start is None:
        print("  无安全起点")
        return
    g.reveal(*start)
    revealed_set = set(g._revealed_positions())
    steps = 1
    print(f"  起点 {start} 翻开后:")
    print(g.render())
    while g.state == GameState.PLAYING and steps < rows * cols:
        click, flag = solver.next_move(revealed_set)
        if not click:
            print("  求解器无法继续推进（异常）")
            break
        for p in sorted(click):
            if g.board.cells[p[0]][p[1]].is_mine:
                print(f"  [错误] 求解器建议点击雷格 {p}")
                break
            g.reveal(*p)
            steps += 1
            if g.state != GameState.PLAYING:
                break
            revealed_set = set(g._revealed_positions())
        for p in sorted(flag):
            if not g.board.cells[p[0]][p[1]].is_flagged:
                g.toggle_flag(*p)
    print(f"  共 {steps} 步，最终状态: {g.state}")
    print(g.render())


def main():
    # 唯一解盘渲染演示（不完整对局，仅展示界面）
    print("#" * 70)
    print("# 三种棋盘：唯一解盘渲染展示")
    print("#" * 70)
    gen = UniqueBoardGenerator(random.Random(1))
    for name, p in BOARD_PRESETS.items():
        rows, cols, mines = p["rows"], p["cols"], p["mines"]
        board = gen.generate(rows, cols, mines, max_attempts=300)
        ok = board is not None and LogicSolver(board).is_unique()
        print(f"[{name}] {rows}x{cols}/{mines}雷 -> 唯一解: {'yes' if ok else 'no'}")

    print()
    print("#" * 70)
    print("# 求解器引导完整对局演示")
    print("#" * 70)
    demo_solver_play("beginner(9x9)", 9, 9, 10, 2026)
    demo_solver_play("intermediate(16x16)", 16, 16, 40, 7)
    demo_solver_play("expert(16x30)", 16, 30, 99, 5)


if __name__ == "__main__":
    main()
