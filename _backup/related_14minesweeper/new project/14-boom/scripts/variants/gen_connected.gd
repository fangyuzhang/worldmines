extends VariantBase
## 连通单块 CC（GDD §3.1.7）：所有雷恰构成 1 个四连通分量。
## 生成采用"生长法"：随机起点，逐步向四邻扩展直到达到目标雷数。

func _init() -> void:
	id = "CC"
	display_name = "连通单块"
	category = Category.GENERATION
	difficulty = 5
	compat_score = 5.0
	weight = "heavy"

func conflict_table() -> Dictionary:
	return { "PF": 3.0, "SC": 2.0, "HaloDiff": 2.0, "LoopRuns": 2.0 }

func check_constraints(board: Board) -> bool:
	# 找到第一个雷，BFS 数连通雷数
	var total: int = board.count_mines()
	if total == 0:
		return false
	var seen := {}
	var stack: Array[Vector2i] = []
	var start_found := false
	for r in board.rows:
		for c in board.cols:
			if board.is_mine(r, c):
				stack.append(Vector2i(r, c))
				start_found = true
				break
		if start_found:
			break
	var connected := 0
	while not stack.is_empty():
		var p: Vector2i = stack.pop_back()
		if seen.has(p):
			continue
		seen[p] = true
		connected += 1
		for nb in board.neighbor4_coords(p.x, p.y):
			if board.is_mine(nb.x, nb.y) and not seen.has(nb):
				stack.append(nb)
	return connected == total

func place_all_mines(board: Board, mine_count: int, rng: RandomNumberGenerator) -> bool:
	var total_cells: int = board.rows * board.cols
	if mine_count < 1 or mine_count > total_cells:
		return false
	# 随机起点
	var start := Vector2i(rng.randi_range(0, board.rows - 1), rng.randi_range(0, board.cols - 1))
	board.set_mine(start.x, start.y, true)
	var placed := 1
	var frontier: Array[Vector2i] = []
	for nb in board.neighbor4_coords(start.x, start.y):
		frontier.append(nb)
	var in_region := { start: true }
	while placed < mine_count and not frontier.is_empty():
		var idx := rng.randi_range(0, frontier.size() - 1)
		var p: Vector2i = frontier[idx]
		frontier.remove_at(idx)
		if in_region.has(p) or board.is_mine(p.x, p.y):
			continue
		if not board.in_bounds(p.x, p.y):
			continue
		board.set_mine(p.x, p.y, true)
		in_region[p] = true
		placed += 1
		for nb in board.neighbor4_coords(p.x, p.y):
			if not in_region.has(nb) and not board.is_mine(nb.x, nb.y):
				frontier.append(nb)
	return placed == mine_count
