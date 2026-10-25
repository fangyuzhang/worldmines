extends VariantBase
## 四象 Quadrant（GDD §3.1.4）：去掉中央行/列后，四个象限雷数相等。
## 采用 GDD 推荐精确划分：R/C 偶无中央，奇有 1 行/列中央。

func _init() -> void:
	id = "Quadrant"
	display_name = "四象"
	category = Category.GENERATION
	difficulty = 3
	compat_score = 8.0
	weight = "light"

func conflict_table() -> Dictionary:
	return { "MX": 2.0, "EP": 2.0 }

## 象限划分：返回 Array[Array]，每个元素是 Array[Vector2i]（一个象限的格子）
func _quadrants(board: Board) -> Array:
	var rows: int = board.rows
	var cols: int = board.cols
	var mid_r: int = rows / 2
	var mid_c: int = cols / 2
	var top_r: int = (rows - 1) / 2  # 中央行（R 奇时 = mid_r）
	var left_c: int = (cols - 1) / 2  # 中央列
	var q: Array = [[], [], [], []]
	for r in rows:
		for c in cols:
			if rows % 2 == 1 and r == top_r:
				continue  # 中央行
			if cols % 2 == 1 and c == left_c:
				continue  # 中央列
			var band_r: int = 0
			if r > top_r:
				band_r = 1
			elif r > mid_r:
				band_r = 1
			var band_c: int = 0
			if c > left_c:
				band_c = 1
			elif c > mid_c:
				band_c = 1
			(q[band_r * 2 + band_c] as Array).append(Vector2i(r, c))
	return q

func check_constraints(board: Board) -> bool:
	var q := _quadrants(board)
	var n: int = -1
	for quad_raw in q:
		var quad: Array = quad_raw as Array
		var cnt := 0
		for p in quad:
			if board.is_mine(p.x, p.y):
				cnt += 1
		if n == -1:
			n = cnt
		elif cnt != n:
			return false
	return true

func place_all_mines(board: Board, mine_count: int, rng: RandomNumberGenerator) -> bool:
	var q := _quadrants(board)
	# 每象限雷数 k；若四象限大小不同（边界情况）则用最小大小约束
	var min_size: int = 1 << 30
	for quad_raw in q:
		var quad: Array = quad_raw as Array
		min_size = mini(min_size, quad.size())
	var max_k: int = mini(min_size, mine_count / 4)
	var k: int = rng.randi_range(0, max_k)
	var used := 0
	for quad_raw in q:
		var quad: Array = quad_raw as Array
		for p in _pick_random(quad, k, rng):
			board.set_mine(p.x, p.y, true)
		used += k
	# 中央行/列与剩余随机
	var center_cells: Array[Vector2i] = []
	var rows: int = board.rows
	var cols: int = board.cols
	var top_r: int = (rows - 1) / 2
	var left_c: int = (cols - 1) / 2
	if rows % 2 == 1:
		for c in cols:
			center_cells.append(Vector2i(top_r, c))
	if cols % 2 == 1:
		for r in rows:
			center_cells.append(Vector2i(r, left_c))
	# 去重
	var seen := {}
	var dedup: Array[Vector2i] = []
	for p in center_cells:
		if not seen.has(p):
			seen[p] = true
			dedup.append(p)
	var remaining: int = mine_count - used
	if remaining > dedup.size():
		return false
	for p in _pick_random(dedup, remaining, rng):
		board.set_mine(p.x, p.y, true)
	return true

## 参数用无类型 Array，元素实际是 Vector2i；返回类型化 Array[Vector2i]
func _pick_random(cells: Array, n: int, rng: RandomNumberGenerator) -> Array[Vector2i]:
	var pool: Array = cells.duplicate()
	var out: Array[Vector2i] = []
	for i in n:
		if pool.is_empty():
			break
		var idx := rng.randi_range(0, pool.size() - 1)
		out.append(pool[idx] as Vector2i)
		pool.remove_at(idx)
	return out
