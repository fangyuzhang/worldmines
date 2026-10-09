class_name ProgressCheck
extends RefCounted

## 试玩期「检查进度（标记插错的旗）」（文档 §7）的**判据**：哪些已插的旗插错了。
##
## 【为什么单独成模块】判据只能有一处：画红叉的地方（board_view）与将来任何
## 「这关被玩通了没有 / 错了几面旗」的统计、回放，都必须问同一个函数。
## UI 里再写一遍 `if board.is_mine(p): continue` 这种小循环，迟早会与它漂移
##（本仓已经有过一次「教程承诺画红叉、实现里压根没画」的同形事故）。
##
## 【口径】
##   · 只数**已插旗**（`Cell.State.FLAGGED`）的格；真值来自 `Board.is_mine`（作者视角）。
##   · 顺序按 `grid.all_positions()`（异形盘的洞格天然不在其中）⇒ 结果稳定、可直接断言。
##   · 零信任：盘 / 网格为空时返回空数组，绝不抛错（编辑器与游戏都可能拿到半初始化的盘）。
static func wrong_flags(board: Board) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if board == null or board.grid == null:
		return out
	for p in board.grid.all_positions():
		var pos: Vector2i = p
		var cell: Cell = board.grid.get_cell(pos)
		if cell == null or cell.state != Cell.State.FLAGGED:
			continue
		if board.is_mine(pos):
			continue
		out.append(pos)
	return out
