class_name BoardGenerator
extends RefCounted
## A 类生成层管线：根据 A 类变体的约束生成满足条件的雷阵。
##
## 策略（GDD §4.1.2）：
## 1. 纯随机放置目标雷数
## 2. 用所有 A 类变体的 check_constraints 做拒绝采样，不满足则重排
## 3. 返回满足全部约束的 Board（否则返回 null）

const MAX_ATTEMPTS := 300

var gen_variants: Array = []  # Array[VariantBase]，仅含 A 类

func _init(variants: Array = []) -> void:
	gen_variants = variants.filter(func(v): return v.category == VariantBase.Category.GENERATION)

static func from_ids(ids: Array) -> BoardGenerator:
	var vars: Array = []
	for id_str in ids:
		var v = VariantRegistry.get_variant(id_str)
		if v:
			vars.append(v)
	return BoardGenerator.new(vars)

## 生成雷阵。rng 传 null 时自动用随机种子。
## 返回 Board；尝试次数耗尽返回 null。
func generate(rows: int, cols: int, mine_count: int, rng: RandomNumberGenerator = null) -> Board:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	if mine_count < 0 or mine_count > rows * cols:
		return null
	for attempt in MAX_ATTEMPTS:
		var board := Board.new(rows, cols)
		_place_random_mines(board, mine_count, rng)
		if _check_all(board):
			return board
	return null

func _place_random_mines(board: Board, mine_count: int, rng: RandomNumberGenerator) -> void:
	var positions: Array[Vector2i] = []
	for r in board.rows:
		for c in board.cols:
			positions.append(Vector2i(r, c))
	# Fisher-Yates + rng 保证确定性
	for i in range(positions.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := positions[i]
		positions[i] = positions[j]
		positions[j] = tmp
	for i in mine_count:
		var p := positions[i]
		board.set_mine(p.x, p.y, true)

func _check_all(board: Board) -> bool:
	for v in gen_variants:
		if not v.check_constraints(board):
			return false
	return true

## 首次点击安全（GDD §2.1.4）：确保首点格及其 8 邻无雷。
## 若原雷阵违反，则重新生成。返回 null 表示无法满足（通常因雷数过大）。
func ensure_first_click_safe(board: Board, first_r: int, first_c: int, rng: RandomNumberGenerator = null) -> Board:
	var safe_cells: Array[Vector2i] = [Vector2i(first_r, first_c)]
	for nb in board.neighbor8_coords(first_r, first_c):
		safe_cells.append(nb)
	var mine_count := board.count_mines()

	# 先检查当前雷阵是否已安全
	var need_move := false
	for sc in safe_cells:
		if board.is_mine(sc.x, sc.y):
			need_move = true
			break
	if not need_move:
		return board

	# 重新生成直到首点安全
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	for attempt in MAX_ATTEMPTS:
		var b := Board.new(board.rows, board.cols)
		_place_random_mines(b, mine_count, rng)
		var safe := true
		for sc in safe_cells:
			if b.is_mine(sc.x, sc.y):
				safe = false
				break
		if not safe:
			continue
		if _check_all(b):
			return b
	return null
