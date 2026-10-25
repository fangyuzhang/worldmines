extends VariantBase
## 纵横分计 HV（GDD §3.2.5）：每格显示两个数字 H/V。
## H = 上下左右四邻雷数，V = 四个斜对角雷数。

func _init() -> void:
	id = "HV"
	display_name = "纵横分计"
	category = Category.NUMBER_RULE
	difficulty = 2
	compat_score = 9.0
	weight = "light"

func _h(board: Board, r: int, c: int) -> int:
	var n := 0
	for nb in board.neighbor4_coords(r, c):
		if board.is_mine(nb.x, nb.y):
			n += 1
	return n

func _v(board: Board, r: int, c: int) -> int:
	var n := 0
	for off in [Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(1, 1)]:
		var nr: int = r + off.x
		var nc: int = c + off.y
		if board.in_bounds(nr, nc) and board.is_mine(nr, nc):
			n += 1
	return n

func compute_clues(board: Board, r: int, c: int) -> Array[VariantClue]:
	if board.is_mine(r, c):
		return []
	var h := _h(board, r, c)
	var v := _v(board, r, c)
	return [VariantClue.new("%d/%d" % [h, v], h == 0 and v == 0)]

func is_flood_seed(board: Board, r: int, c: int) -> bool:
	if board.is_mine(r, c):
		return false
	return _h(board, r, c) == 0 and _v(board, r, c) == 0

func cell_display(board: Board, r: int, c: int) -> String:
	if board.is_mine(r, c):
		return "💣"
	return "%d/%d" % [_h(board, r, c), _v(board, r, c)]
