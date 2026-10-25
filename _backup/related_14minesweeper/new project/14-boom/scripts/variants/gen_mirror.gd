extends VariantBase
## 镜像 MX（GDD §3.1.1）：雷的排布关于棋盘中央竖轴对称。
## grid[r][c] = grid[r][C-1-c]。
## A 类生成层约束：只影响雷怎么放，不影响数字计算。

func _init() -> void:
	id = "MX"
	display_name = "镜像"
	category = Category.GENERATION
	difficulty = 2
	compat_score = 8.0
	weight = "light"

## 与行首尾 RF 强冲突（GDD §4.1.3）：镜像要求两端相同，行首尾要求相反 → 无解
func conflict_table() -> Dictionary:
	return { "RF": 10.0, "EP": 2.0, "Quadrant": 2.0 }

func check_constraints(board: Board) -> bool:
	for r in board.rows:
		for c in board.cols:
			var mirror_c: int = board.cols - 1 - c
			if board.is_mine(r, c) != board.is_mine(r, mirror_c):
				return false
	return true

## 定向生成：只在左半（含中央列）随机布雷，右半镜像复制。
## 中央列（C 为奇数时存在）自己和自己对称，不破坏奇偶性。
func place_all_mines(board: Board, mine_count: int, rng: RandomNumberGenerator) -> bool:
	var half_cols: int = (board.cols + 1) / 2  # 左半宽度（含中央列）
	# 先随机选左半中的"镜像对"数：需要 mine_count 颗雷按对称放置。
	# 若 C 为偶数，总雷数必为偶数；若 C 为奇数，中央列可单独放任意数。
	var central_count: int = 0
	if board.cols % 2 == 1:
		# 中央列的自对称格：决定放几颗。其余雷成对放在左右。
		central_count = rng.randi_range(0, mini(2, mine_count))
	var pair_mines: int = mine_count - central_count
	if pair_mines % 2 != 0:
		# 调整为偶数（奇数列时把多余的 1 颗移到中央列）
		if board.cols % 2 == 1 and central_count + 1 <= board.rows:
			central_count += 1
			pair_mines -= 1
		else:
			return false
	# 左半（不含中央列）的候选格
	var left_cells: Array[Vector2i] = []
	for r in board.rows:
		for c in half_cols:
			if board.cols % 2 == 1 and c == half_cols - 1:
				continue  # 跳过中央列
			left_cells.append(Vector2i(r, c))
	# 从 left_cells 随机选 pair_mines/2 个
	var chosen: Array[Vector2i] = _pick_random(left_cells, pair_mines / 2, rng)
	for p in chosen:
		var mirror_c: int = board.cols - 1 - p.y
		board.set_mine(p.x, p.y, true)
		board.set_mine(p.x, mirror_c, true)
	# 中央列布雷
	if central_count > 0:
		var center_cells: Array[Vector2i] = []
		var center_col: int = (board.cols - 1) / 2
		for r in board.rows:
			center_cells.append(Vector2i(r, center_col))
		for p in _pick_random(center_cells, central_count, rng):
			board.set_mine(p.x, p.y, true)
	return true

## 从 cells 中不重复随机抽取 n 个
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
