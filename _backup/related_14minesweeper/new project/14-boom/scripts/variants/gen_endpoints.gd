extends VariantBase
## 端点平衡 EP（GDD §3.1.3）：最左列与最右列的雷数完全相等。
## count(col0) == count(colC-1)。A 类生成层约束。

func _init() -> void:
	id = "EP"
	display_name = "端点平衡"
	category = Category.GENERATION
	difficulty = 3
	compat_score = 8.0
	weight = "light"

func conflict_table() -> Dictionary:
	return { "MX": 2.0, "Quadrant": 2.0 }

func check_constraints(board: Board) -> bool:
	var left := 0
	var right := 0
	for r in board.rows:
		if board.is_mine(r, 0):
			left += 1
		if board.is_mine(r, board.cols - 1):
			right += 1
	return left == right

func place_all_mines(board: Board, mine_count: int, rng: RandomNumberGenerator) -> bool:
	var rows: int = board.rows
	var inner_cells: Array[Vector2i] = []
	for r in rows:
		for c in range(1, board.cols - 1):
			inner_cells.append(Vector2i(r, c))
	var max_k: int = min(rows, mine_count / 2)
	var k: int = rng.randi_range(0, max_k)
	var left_col: Array[Vector2i] = []
	var right_col: Array[Vector2i] = []
	for r in rows:
		left_col.append(Vector2i(r, 0))
		right_col.append(Vector2i(r, board.cols - 1))
	for p in _pick_random(left_col, k, rng):
		board.set_mine(p.x, p.y, true)
	for p in _pick_random(right_col, k, rng):
		board.set_mine(p.x, p.y, true)
	var remaining: int = mine_count - 2 * k
	if remaining > inner_cells.size():
		return false
	for p in _pick_random(inner_cells, remaining, rng):
		board.set_mine(p.x, p.y, true)
	return true

func _pick_random(cells: Array[Vector2i], n: int, rng: RandomNumberGenerator) -> Array[Vector2i]:
	var pool := cells.duplicate()
	var out: Array[Vector2i] = []
	for i in n:
		if pool.is_empty():
			break
		var idx := rng.randi_range(0, pool.size() - 1)
		out.append(pool[idx])
		pool.remove_at(idx)
	return out
