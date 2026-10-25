extends VariantBase
## 四邻 4N（GDD §3.2.1）：数字 = 上下左右 4 邻雷数，斜角不参与。
## 兼容性满分，是变体组合的"基础数字规则"。

func _init() -> void:
	id = "4N"
	display_name = "四邻"
	category = Category.NUMBER_RULE
	difficulty = 1
	compat_score = 10.0
	weight = "light"

func _adjacent4(board: Board, r: int, c: int) -> int:
	var n := 0
	for nb in board.neighbor4_coords(r, c):
		if board.is_mine(nb.x, nb.y):
			n += 1
	return n

func compute_clues(board: Board, r: int, c: int) -> Array[VariantClue]:
	if board.is_mine(r, c):
		return []
	var n := _adjacent4(board, r, c)
	return [VariantClue.new(str(n), n == 0, n)]

func is_flood_seed(board: Board, r: int, c: int) -> bool:
	if board.is_mine(r, c):
		return false
	return _adjacent4(board, r, c) == 0

func cell_display(board: Board, r: int, c: int) -> String:
	if board.is_mine(r, c):
		return "💣"
	var n := _adjacent4(board, r, c)
	return "" if n == 0 else str(n)
