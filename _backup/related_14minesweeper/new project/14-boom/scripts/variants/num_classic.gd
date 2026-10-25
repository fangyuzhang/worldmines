extends VariantBase
## 经典扫雷数字规则（8 邻雷数）—— B 类基线 / 兜底规则。
## 这是最简单的一个变体模块，作为新增变体的参考范式。

func _init() -> void:
	id = "classic"
	display_name = "经典数字"
	category = Category.NUMBER_RULE
	difficulty = 1
	compat_score = 10.0
	weight = "light"

func compute_clues(board: Board, r: int, c: int) -> Array[VariantClue]:
	if board.is_mine(r, c):
		return []
	var n := board.adjacent_mines(r, c)
	return [VariantClue.new(str(n), n == 0, n)]

func is_flood_seed(board: Board, r: int, c: int) -> bool:
	if board.is_mine(r, c):
		return false
	return board.adjacent_mines(r, c) == 0

func cell_display(board: Board, r: int, c: int) -> String:
	if board.is_mine(r, c):
		return "💣"
	var n := board.adjacent_mines(r, c)
	return "" if n == 0 else str(n)
