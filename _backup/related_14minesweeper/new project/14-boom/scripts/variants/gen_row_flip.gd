extends VariantBase
## 行首尾 RF（GDD §3.1.2）：每一行的最左格与最右格的雷状态相反。
## grid[r][0] ≠ grid[r][C-1]。
## A 类生成层约束。

func _init() -> void:
	id = "RF"
	display_name = "行首尾"
	category = Category.GENERATION
	difficulty = 2
	compat_score = 8.0
	weight = "light"

## 与镜像 MX 强冲突（GDD §4.1.3 明确标注为强矛盾对）
func conflict_table() -> Dictionary:
	return { "MX": 10.0, "EP": 1.0 }

func check_constraints(board: Board) -> bool:
	if board.cols < 2:
		return false
	for r in board.rows:
		if board.is_mine(r, 0) == board.is_mine(r, board.cols - 1):
			return false
	return true

## 定向生成：每行两端恰好一雷一安，内部随机。
## 生成时先决定每行左端是否雷（右端自动取反），再从内部随机补充剩余雷。
func place_all_mines(board: Board, mine_count: int, rng: RandomNumberGenerator) -> bool:
	# 每行两端恰一雷 → 至少需要 board.rows 颗雷用于两端
	if mine_count < board.rows:
		return false
	var interior_cells: Array[Vector2i] = []
	for r in board.rows:
		if rng.randf() < 0.5:
			board.set_mine(r, 0, true)          # 左端雷
		else:
			board.set_mine(r, board.cols - 1, true)  # 右端雷
		for c in range(1, board.cols - 1):
			interior_cells.append(Vector2i(r, c))
	var remaining: int = mine_count - board.rows
	if remaining > interior_cells.size():
		return false
	var chosen: Array[Vector2i] = _pick_random(interior_cells, remaining, rng)
	for p in chosen:
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
