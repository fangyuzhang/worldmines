extends VariantBase
## 环游程 LoopRuns（GDD §3.2.7）：8 邻按顺时针排成环，数字 = 环上雷的连续段数。
## 越界位置视为"安全"（非雷）。0 表示 8 邻全安全（触发洪水）。

func _init() -> void:
	id = "LoopRuns"
	display_name = "环游程"
	category = Category.NUMBER_RULE
	difficulty = 5
	compat_score = 7.0
	weight = "heavy"

func conflict_table() -> Dictionary:
	return { "CC": 2.0 }

const CLOCK_OFFSETS: Array[Vector2i] = [
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, -1),
]

func _runs(board: Board, r: int, c: int) -> int:
	# 8 个位置是否雷（越界视为安全）
	var mines: Array[bool] = []
	for off in CLOCK_OFFSETS:
		var nr: int = r + off.x
		var nc: int = c + off.y
		mines.append(board.in_bounds(nr, nc) and board.is_mine(nr, nc))
	var count := 0
	for i in 8:
		var prev: bool = mines[(i + 7) % 8]
		if mines[i] and not prev:
			count += 1
	return count

func compute_clues(board: Board, r: int, c: int) -> Array[VariantClue]:
	if board.is_mine(r, c):
		return []
	var val := _runs(board, r, c)
	return [VariantClue.new(str(val), val == 0)]

func is_flood_seed(board: Board, r: int, c: int) -> bool:
	if board.is_mine(r, c):
		return false
	return _runs(board, r, c) == 0

func cell_display(board: Board, r: int, c: int) -> String:
	if board.is_mine(r, c):
		return "💣"
	var val := _runs(board, r, c)
	return "" if val == 0 else str(val)
