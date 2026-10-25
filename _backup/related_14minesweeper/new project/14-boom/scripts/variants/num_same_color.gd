extends VariantBase
## 同色 SC（GDD §3.2.4）：按 (r+c)%2 黑白染色，数字 = 8 邻中同色邻居的雷数。
## 内部格子的同色邻居恰为 4 个斜对角，数字范围 0~4。

func _init() -> void:
	id = "SC"
	display_name = "同色"
	category = Category.NUMBER_RULE
	difficulty = 4
	compat_score = 9.0
	weight = "light"

func conflict_table() -> Dictionary:
	return { "CC": 2.0 }

func _same_color_neighbors(board: Board, r: int, c: int) -> int:
	var my_color := (r + c) % 2
	var n := 0
	for nb in board.neighbor8_coords(r, c):
		if (nb.x + nb.y) % 2 == my_color and board.is_mine(nb.x, nb.y):
			n += 1
	return n

func compute_clues(board: Board, r: int, c: int) -> Array[VariantClue]:
	if board.is_mine(r, c):
		return []
	var val := _same_color_neighbors(board, r, c)
	return [VariantClue.new(str(val), val == 0)]

func is_flood_seed(board: Board, r: int, c: int) -> bool:
	if board.is_mine(r, c):
		return false
	return _same_color_neighbors(board, r, c) == 0

func cell_display(board: Board, r: int, c: int) -> String:
	if board.is_mine(r, c):
		return "💣"
	var val := _same_color_neighbors(board, r, c)
	return "" if val == 0 else str(val)
