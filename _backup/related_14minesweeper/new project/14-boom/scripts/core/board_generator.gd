class_name BoardGenerator
extends RefCounted
## A 类生成层管线：根据 A 类变体的约束生成满足条件的雷阵。
##
## 策略（GDD §4.1.2）：
## 1. 若 A 类变体实现了 place_all_mines（定向生成），优先用它高效布雷；
##    否则用纯随机放置。
## 2. 用所有 A 类变体的 check_constraints 做最终验证（拒绝采样兜底）。
## 3. 若设置了 solvable_clues（B 类线索计算器），再用 Solver 验证"逻辑唯一可解"，
##    不满足则重新生成——保证产出对局无猜雷、无无解局。

const MAX_ATTEMPTS := 400
const MAX_SOLVABLE_ATTEMPTS := 60

var gen_variants: Array = []  # Array[VariantBase]，仅含 A 类
## 唯一解验证用的 B 类线索计算器。设为 null 时跳过可解性过滤（生成更快）。
var solvable_clues: ClueComputer = null

func _init(variants: Array = []) -> void:
	for v in variants:
		if v is VariantBase and (v as VariantBase).category == VariantBase.Category.GENERATION:
			gen_variants.append(v as VariantBase)

static func from_ids(ids: Array) -> BoardGenerator:
	var vars: Array = []
	for id_str in ids:
		var v: VariantBase = VariantRegistry.get_variant(id_str) as VariantBase
		if v:
			vars.append(v)
	return BoardGenerator.new(vars)

## 生成雷阵。rng 传 null 时自动用随机种子。
## 返回满足全部 A 类约束、且（若启用可解性过滤）逻辑唯一可解的 Board；否则 null。
func generate(rows: int, cols: int, mine_count: int, rng: RandomNumberGenerator = null) -> Board:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	if mine_count < 0 or mine_count > rows * cols:
		return null
	var attempts := MAX_ATTEMPTS
	if solvable_clues != null:
		attempts = MAX_SOLVABLE_ATTEMPTS
	for attempt in attempts:
		var board := Board.new(rows, cols)
		if not _place_with_generation(board, mine_count, rng):
			_place_random_mines(board, mine_count, rng)
		if not _check_all(board):
			continue
		if solvable_clues != null and not _is_unique_solution(board, rows, cols, mine_count, rng):
			continue
		return board
	return null

## 用 Solver 验证该雷阵是否逻辑唯一可解。首点选棋盘中心（洪水大概率展开一大片）。
func _is_unique_solution(board: Board, rows: int, cols: int, mine_count: int,
		rng: RandomNumberGenerator) -> bool:
	var solver := Solver.new(board, solvable_clues, mine_count)
	# 找棋盘中心附近第一个安全格作为起点（洪水大概率展开一大片）
	for dr in range(rows):
		for dc in range(cols):
			var rr := (rows / 2 + dr) % rows
			var cc := (cols / 2 + dc) % cols
			if not board.is_mine(rr, cc):
				return solver.is_unique_solution(rr, cc)
	return false

## 尝试用第一个声明了定向生成的 A 类变体布雷。
## 返回 true 表示定向生成成功（之后仍需 _check_all 验证全部约束）。
func _place_with_generation(board: Board, mine_count: int, rng: RandomNumberGenerator) -> bool:
	for v in gen_variants:
		if v.place_all_mines(board, mine_count, rng):
			return true
	return false

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
		if not _place_with_generation(b, mine_count, rng):
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
