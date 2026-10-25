# puzzle_generator.gd —— 关卡生成器（文档 §4.4 全流程）
# 确定性布雷（仅种子 RNG）→ 单点开局 → 遮蔽 → 唯一解验证 → 纯逻辑可解验证。
# 全局约束型用专用布雷策略（镜像/骨牌/象限/端点/四色/行锁），PF 用随机+过滤。
class_name PuzzleGenerator
extends RefCounted

const MAX_ATTEMPTS := 500
const MAX_MINES_RATIO := 0.4  # 默认雷密度上限
# 难度门禁（对齐手工关卡 classic_01~10：初始翻开 2~7 格）
const MIN_OPENING_AREA := 2   # 开局初始翻开格数下限（少于 2 格线索不足）
const MAX_OPENING_AREA := 7   # 开局初始翻开格数上限（超过 7 格难度过低/开局即赢）

var _rng := RandomNumberGenerator.new()


## 生成一个关卡（返回 level dict，可直接 board.load_level）。
## variant_code: VariantRegistry 的变体码；size: [cols, rows]；mines: 雷数（≤0 则自动取 30%）。
## seed: 确定性种子。
func generate(variant_code: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	var def: Dictionary = VariantRegistry.definitions()[variant_code]
	var clue: int = def["clue"]
	var constraint: int = def["constraint"]
	var cols := size.x
	var rows := size.y
	var n := cols * rows
	if mine_count <= 0:
		mine_count = int(n * 0.3)
	mine_count = clampi(mine_count, 1, n - 1)
	# 4C 四向守恒要求总雷数为偶数，向下调整
	if constraint == ConstraintEngine.Variant.FOUR_COLOR:
		mine_count -= mine_count % 2
		mine_count = maxi(mine_count, 2)

	_rng.seed = seed
	_dominoes = []

	# 单点开局要求 minimal_clue_value >= 0；FR 等无弱信息值的变体不支持单点开局（文档 §4.2）
	if int(def.get("min_clue", 0)) < 0:
		return {}

	# 总时间熔断（文档 §10.1 生成器预算 ≤15s；计时非随机熵源）
	var deadline: int = Time.get_ticks_msec() + 15_000

	for attempt in MAX_ATTEMPTS:
		if Time.get_ticks_msec() > deadline:
			push_warning("PuzzleGenerator: 生成超时 %s" % variant_code)
			return {}
		# 1. 确定性布雷（满足全局约束）
		var mines := _place_mines(constraint, cols, rows, mine_count)
		if mines.is_empty():
			continue

		var board := Board.new()
		board.set_variant(clue, constraint, _dominoes)
		board.total_mines = mines.size()
		board._static_mines = mines
		var grid := RectGrid.new()
		grid.setup(rows, cols)
		board.grid = grid
		for m in mines:
			grid.get_cell(m).is_mine = true
		board._compute_clues()

		# 2. 初始线索：选 K 个「非零线索」格（数字格），模拟手工关卡「给少量线索格」
		var openings := _pick_openings(board)
		if openings.is_empty():
			continue

		# 3. 翻开初始线索格
		for o in openings:
			board.reveal(o)
		# 3.5 难度门禁：开局不得「开局即赢」（WON = 无任何推理内容，空壳关卡）
		if board.state == Board.GameState.WON:
			continue

		# 3.6 先构建 level（player.solve 会翻开全盘验证，必须在 solve 前快照初始线索格）
		var level := _build_level(variant_code, rows, cols, mines, board)

		# 4. 唯一解 + 纯逻辑可解验证（用初始视角约束集 S）
		var check := VariantConstraint.new(clue, constraint, _dominoes)
		var check_callable := Callable(check, "check")
		var player := SolverPerfectPlayer.new()
		var result := player.solve(board, check_callable)
		if not result[0]:
			continue  # 不可纯逻辑解或断链，回滚重试

		# 5. 唯一解校验：初始视角约束集 S 的解数 == 1
		var revealed := player._collect_revealed(board)
		var oracle := BruteForceOracle.new()
		var verdict := oracle.query_variant(Vector2i(cols, rows), revealed, mines.size(), check_callable)
		# verdict 非空即至少一解；唯一解由完美玩家成功 + 单点开局隐含（见文档 §3.4 唯一性单查即充分）

		return level

	return {}  # 重试预算耗尽


## 生成全局约束型关卡（带约束布雷 + 骨牌数据）。
func generate_constrained(variant_code: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	_dominoes = []
	return generate(variant_code, size, mine_count, seed)


## 构造式生成（第三篇 P0）：逆向删线索 + 唯一解保持 + 纯逻辑可解验证。
## 从全翻开出发，逐步关闭格子（保持唯一解），得到最少线索的谜题，再验证可解。
## 相比「随机布雷+验证+重试」：唯一解是构造保证的，不需碰运气；但仍需可解验证（唯一解 ≠ 纯逻辑可解）。
func generate_constructive(variant_code: String, size: Vector2i, mine_count: int, seed: int, mask_count: int = 0) -> Dictionary:
	var def: Dictionary = VariantRegistry.resolve(variant_code)
	if def.is_empty():
		return {}
	return _generate_impl(def["clue"], def["constraint"], variant_code, size, mine_count, seed, mask_count)


## 混合变体生成：布局（全局约束）+ 线索型 组合（plan1.8 §3.2 C 类「一布局一线索」）。
## 例：generate_mixed("mx", "4n", ...) = 镜像约束 + 四邻线索。
func generate_mixed(layout_code: String, clue_code: String, size: Vector2i, mine_count: int, seed: int, mask_count: int = 0) -> Dictionary:
	var layout: Dictionary = VariantRegistry.resolve(layout_code)
	var clue: Dictionary = VariantRegistry.resolve(clue_code)
	if layout.is_empty() or clue.is_empty():
		return {}
	return _generate_impl(clue["clue"], layout["constraint"], "%s+%s" % [layout_code, clue_code], size, mine_count, seed, mask_count)


## 双布局生成（F 类）：两个全局约束叠加，线索为经典（plan1.8 §3.2）。
## 例：generate_dual("mx", "rl", ...) = 镜像约束 + 相邻行锁约束。
func generate_dual(layout_a: String, layout_b: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	var da: Dictionary = VariantRegistry.resolve(layout_a)
	var db: Dictionary = VariantRegistry.resolve(layout_b)
	if da.is_empty() or db.is_empty():
		return {}
	var ca: int = da["constraint"]
	var cb: int = db["constraint"]
	if ca == -1 or cb == -1:
		return {}  # 必须都是布局型
	return _generate_dual_impl(ca, cb, "%s+%s" % [layout_a, layout_b], size, mine_count, seed)


func _generate_dual_impl(ca: int, cb: int, code: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	var cols := size.x
	var rows := size.y
	var n := cols * rows
	if mine_count <= 0:
		mine_count = int(n * 0.3)
	mine_count = clampi(mine_count, 1, n - 1)
	if ca == ConstraintEngine.Variant.FOUR_COLOR or cb == ConstraintEngine.Variant.FOUR_COLOR:
		mine_count -= mine_count % 2
		mine_count = maxi(mine_count, 2)
	_rng.seed = seed
	_dominoes = []

	var deadline: int = Time.get_ticks_msec() + 15_000

	for attempt in 50:
		if Time.get_ticks_msec() > deadline:
			push_warning("PuzzleGenerator: 双布局生成超时 %s" % code)
			return {}

		var mines := _place_mines_dual(ca, cb, cols, rows, mine_count)
		if mines.is_empty():
			continue

		var board := _make_board(ClueEngine.Variant.CLASSIC, ca, mines, cols, rows, cb)
		var givens := _prune_clues(board, ClueEngine.Variant.CLASSIC, ca, mines, cols, rows, deadline, cb)
		if givens.is_empty():
			continue

		var play_board := _make_board(ClueEngine.Variant.CLASSIC, ca, mines, cols, rows, cb)
		for g in givens:
			play_board.reveal(g)
		if play_board.state == Board.GameState.WON:
			continue
		var check := VariantConstraint.new(ClueEngine.Variant.CLASSIC, ca, _dominoes, cb)
		var player := SolverPerfectPlayer.new()
		var result := player.solve(play_board, Callable(check, "check"))
		if not result[0]:
			continue

		return _build_level_from_givens(code, rows, cols, mines, givens, {})

	return {}


## 线索混合生成（E 类）：两个线索型叠加，一格同时给出两个线索值（plan1.8 §3.2）。
## 例：generate_mixed_clue("4n", "sc", ...) = 四邻计数 + 同色计数 同时显示。
func generate_mixed_clue(clue_a: String, clue_b: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	var da: Dictionary = VariantRegistry.resolve(clue_a)
	var db: Dictionary = VariantRegistry.resolve(clue_b)
	if da.is_empty() or db.is_empty():
		return {}
	if int(da.get("constraint", -1)) != -1 or int(db.get("constraint", -1)) != -1:
		return {}  # 必须都是线索型
	return _generate_impl_clue2(da["clue"], db["clue"], "%s+%s" % [clue_a, clue_b], size, mine_count, seed)


func _generate_impl_clue2(c1: int, c2: int, code: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	var cols := size.x
	var rows := size.y
	var n := cols * rows
	if mine_count <= 0:
		mine_count = int(n * 0.3)
	mine_count = clampi(mine_count, 1, n - 1)
	_rng.seed = seed
	_dominoes = []

	var deadline: int = Time.get_ticks_msec() + 15_000

	for attempt in 50:
		if Time.get_ticks_msec() > deadline:
			push_warning("PuzzleGenerator: 线索混合生成超时 %s" % code)
			return {}

		var mines := _place_random(cols, rows, mine_count)
		if mines.is_empty():
			continue

		var board := _make_board(c1, -1, mines, cols, rows, -1, c2)
		var givens := _prune_clues(board, c1, -1, mines, cols, rows, deadline, -1, c2)
		if givens.is_empty():
			continue

		var play_board := _make_board(c1, -1, mines, cols, rows, -1, c2)
		for g in givens:
			play_board.reveal(g)
		if play_board.state == Board.GameState.WON:
			continue
		var check := VariantConstraint.new(c1, -1, _dominoes, -1, c2)
		var player := SolverPerfectPlayer.new()
		var result := player.solve(play_board, Callable(check, "check"))
		if not result[0]:
			continue

		return _build_level_from_givens(code, rows, cols, mines, givens, {})

	return {}


## 从 mod Def 生成关卡（第二篇 mod 系统，用内置 DefEngine）。
## clue_def_name 必填；constraint_def_name 可选（空 = 无全局约束）。
func generate_from_def(clue_def_name: String, constraint_def_name: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	return generate_with_engine(DefEngine.new(), clue_def_name, constraint_def_name, size, mine_count, seed)


## 从指定 DefEngine 生成关卡（供 ModService 用含 mod Def 的共享 engine 生成 mod 关卡）。
func generate_with_engine(engine: DefEngine, clue_def_name: String, constraint_def_name: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	if not engine.clue_defs.has(clue_def_name):
		return {}
	if constraint_def_name != "" and not engine.constraint_defs.has(constraint_def_name):
		return {}
	return _generate_def_impl(engine, clue_def_name, constraint_def_name, size, mine_count, seed)


func _generate_def_impl(engine: DefEngine, clue_def_name: String, constraint_def_name: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	var cols := size.x
	var rows := size.y
	var n := cols * rows
	if mine_count <= 0:
		mine_count = int(n * 0.3)
	mine_count = clampi(mine_count, 1, n - 1)
	_rng.seed = seed
	_dominoes = []
	var constraint := _def_op_to_constraint(engine, constraint_def_name)
	var deadline: int = Time.get_ticks_msec() + 15_000

	for attempt in 50:
		if Time.get_ticks_msec() > deadline:
			push_warning("PuzzleGenerator: mod 生成超时 %s" % clue_def_name)
			return {}

		var mines := _place_mines(constraint, cols, rows, mine_count)
		if mines.is_empty():
			continue

		var board := _make_board_from_def(engine, clue_def_name, mines, cols, rows)
		var givens := _prune_clues_def(board, engine, clue_def_name, constraint_def_name, mines, cols, rows, deadline)
		if givens.is_empty():
			continue

		var play_board := _make_board_from_def(engine, clue_def_name, mines, cols, rows)
		for g in givens:
			play_board.reveal(g)
		if play_board.state == Board.GameState.WON:
			continue
		var check := DefConstraint.new(engine, clue_def_name, constraint_def_name, _dominoes)
		if not _solve_with_check(play_board, check):
			continue

		return _build_level_from_def(clue_def_name, constraint_def_name, rows, cols, mines, givens)

	return {}


## mod 约束 Def 的 op → 内置约束枚举（用于确定性布雷）。未知 op → -1（随机布雷）。
func _def_op_to_constraint(engine: DefEngine, constraint_def_name: String) -> int:
	if constraint_def_name == "" or not engine.constraint_defs.has(constraint_def_name):
		return -1
	var op: String = engine.constraint_defs[constraint_def_name].get("op", "")
	match op:
		DefEngine.OP_SYMMETRY_AXIS:
			return ConstraintEngine.Variant.MX
		DefEngine.OP_SEQUENCE_DIFF:
			return ConstraintEngine.Variant.RL
		DefEngine.OP_PATTERN_FORBIDDEN:
			return ConstraintEngine.Variant.PF
		DefEngine.OP_QUADRANT_EQUAL:
			return ConstraintEngine.Variant.QD
		DefEngine.OP_ENDPOINT_EQUAL:
			return ConstraintEngine.Variant.EP
		DefEngine.OP_COLOR_EQUAL:
			return ConstraintEngine.Variant.FOUR_COLOR
		DefEngine.OP_PARTITION_PAIRING:
			return ConstraintEngine.Variant.DT
		_:
			return -1


## 建盘并用 DefEngine 计算线索值。
func _make_board_from_def(engine: DefEngine, clue_def_name: String, mines: Array[Vector2i], cols: int, rows: int) -> Board:
	var board := Board.new()
	board.total_mines = mines.size()
	board._static_mines = mines
	board.def_engine = engine
	board.clue_def_name = clue_def_name
	var grid := RectGrid.new()
	grid.setup(rows, cols)
	board.grid = grid
	for m in mines:
		grid.get_cell(m).is_mine = true
	var mine_set := board._mine_set_dict()
	var size := Vector2i(cols, rows)
	for r in rows:
		for c in cols:
			var pos := Vector2i(c, r)
			var cell := grid.get_cell(pos)
			if cell.is_mine:
				continue
			cell.value = engine.compute_clue(clue_def_name, mine_set, pos, size)
	return board


## mod Def 逆向删线索（保持唯一解）：用 DefConstraint 的 check 回调 + 变体回溯。
func _prune_clues_def(board: Board, engine: DefEngine, clue_def_name: String, constraint_def_name: String, mines: Array[Vector2i], cols: int, rows: int, deadline: int) -> Array[Vector2i]:
	var gsize := board.grid.size()
	var revealed_set := {}
	var non_mine: Array[Vector2i] = []
	for r in gsize.y:
		for c in gsize.x:
			var pos := Vector2i(c, r)
			if not board.is_mine(pos):
				revealed_set[pos] = true
				non_mine.append(pos)

	var check := DefConstraint.new(engine, clue_def_name, constraint_def_name, _dominoes)
	var check_callable := Callable(check, "check")
	var total := mines.size()
	var oracle := BruteForceOracle.new()
	var _b := board
	non_mine.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var va: Variant = _b.grid.get_cell(a).value
		var vb: Variant = _b.grid.get_cell(b).value
		var na: float = float(va) if va is int else 0.0
		var nb: float = float(vb) if vb is int else 0.0
		if na != nb:
			return na < nb
		return a.y < b.y or (a.y == b.y and a.x < b.x)
	)

	for pos in non_mine:
		if Time.get_ticks_msec() > deadline:
			break
		revealed_set.erase(pos)
		var constraints := _collect_constraints(board, revealed_set)
		var cnt: int = oracle.count_solutions_variant(Vector2i(cols, rows), constraints, total, check_callable, [], 2)
		if cnt != 1:
			revealed_set[pos] = true

	var givens: Array[Vector2i] = []
	for pos in revealed_set:
		givens.append(pos)
	return givens


## 完美玩家模拟（通用 check 回调路径，不依赖内置 clue_variant 分派）。
func _solve_with_check(board: Board, check: DefConstraint) -> bool:
	var gsize := board.grid.size()
	var total := board.total_mines
	var known_mines: Array[Vector2i] = []
	var steps := 0
	var check_callable := Callable(check, "check")
	var oracle := BruteForceOracle.new()
	while true:
		if board.state == Board.GameState.WON:
			return true
		if board.state == Board.GameState.LOST:
			return false
		if steps > gsize.x * gsize.y * 12:
			return false
		var revealed := {}
		for r in gsize.y:
			for c in gsize.x:
				var pos := Vector2i(c, r)
				var cell := board.grid.get_cell(pos)
				if cell.state == Cell.State.REVEALED:
					revealed[pos] = board.get_player_constraint(pos)
		var remaining := total - known_mines.size()
		var verdict := oracle.query_variant(gsize, revealed, remaining, check_callable, known_mines)
		var safe: Array[Vector2i] = []
		for r in gsize.y:
			for c in gsize.x:
				var pos := Vector2i(c, r)
				var cell := board.grid.get_cell(pos)
				if cell.state != Cell.State.REVEALED and not board.is_mine(pos):
					if verdict.get(pos) == "safe":
						safe.append(pos)
		var mine: Array[Vector2i] = []
		for m in board.get_mine_positions():
			if not known_mines.has(m) and verdict.get(m) == "mine":
				mine.append(m)
		if safe.is_empty() and mine.is_empty():
			return false
		for p in safe:
			board.reveal(p)
		for m in mine:
			known_mines.append(m)
		steps += 1
	return false


## mod 关卡 JSON（clue_def / constraint_def 字段 + 坐标 + 初始翻开格）。
func _build_level_from_def(clue_def_name: String, constraint_def_name: String, rows: int, cols: int, mines: Array[Vector2i], givens: Array[Vector2i]) -> Dictionary:
	var revealed: Array = []
	for g in givens:
		revealed.append({"r": g.y, "c": g.x})
	var mines_arr: Array = []
	for m in mines:
		mines_arr.append({"r": m.y, "c": m.x})
	return {
		"clue_def": clue_def_name,
		"constraint_def": constraint_def_name,
		"size": {"rows": rows, "cols": cols},
		"total_mines": mines.size(),
		"mines": mines_arr,
		"revealed": revealed,
		"dominoes": _serialize_dominoes(_dominoes),
	}


func _generate_impl(clue: int, constraint: int, variant_code: String, size: Vector2i, mine_count: int, seed: int, mask_count: int) -> Dictionary:
	var cols := size.x
	var rows := size.y
	var n := cols * rows
	if mine_count <= 0:
		mine_count = int(n * 0.3)
	mine_count = clampi(mine_count, 1, n - 1)
	if constraint == ConstraintEngine.Variant.FOUR_COLOR:
		mine_count -= mine_count % 2
		mine_count = maxi(mine_count, 2)
	# ★ 构造式从「全翻开」出发逆向删线索，无需单点开局，故 FR 亦可参与（min_clue 门禁仅约束 generate()）。
	_rng.seed = seed
	_dominoes = []

	var deadline: int = Time.get_ticks_msec() + 15_000

	for attempt in 50:
		if Time.get_ticks_msec() > deadline:
			push_warning("PuzzleGenerator: 构造式生成超时 %s" % variant_code)
			return {}

		# 1. 确定性布雷（满足全局约束）
		var mines := _place_mines(constraint, cols, rows, mine_count)
		if mines.is_empty():
			continue

		# 2. 建棋盘 + 计算线索
		var board := _make_board(clue, constraint, mines, cols, rows)

		# 3. 逆向删线索（保持唯一解）
		var givens := _prune_clues(board, clue, constraint, mines, cols, rows, deadline)
		if givens.is_empty():
			continue

		# 3.5 遮蔽：选 mask_count 个「值 ≥1」的 given 变成 ? 格（interval 约束，弱化线索）
		var masked := _select_masked(board, givens, mask_count)

		# 4. 纯逻辑可解验证（settle：翻开 givens 触发连锁扩散；遮蔽格先设 interval 再 reveal）
		var play_board := _make_board(clue, constraint, mines, cols, rows)
		for g in givens:
			if masked.has(g):
				play_board.grid.get_cell(g).hidden_interval = masked[g]
			play_board.reveal(g)
		# 4.5 难度门禁：settle 后不得「开局即赢」（WON on load = 无任何推理内容）
		if play_board.state == Board.GameState.WON:
			continue
		var check := VariantConstraint.new(clue, constraint, _dominoes)
		var player := SolverPerfectPlayer.new()
		var result := player.solve(play_board, Callable(check, "check"))
		if not result[0]:
			continue

		# 5. 输出
		return _build_level_from_givens(variant_code, rows, cols, mines, givens, masked)

	return {}


## 建棋盘 + 布雷 + 计算线索。constraint2 为双布局第二约束；clue2 为线索混合第二线索型。
func _make_board(clue: int, constraint: int, mines: Array[Vector2i], cols: int, rows: int, constraint2: int = -1, clue2: int = -1) -> Board:
	var board := Board.new()
	board.set_variant(clue, constraint, _dominoes, constraint2, clue2)
	board.total_mines = mines.size()
	board._static_mines = mines
	var grid := RectGrid.new()
	grid.setup(rows, cols)
	board.grid = grid
	for m in mines:
		grid.get_cell(m).is_mine = true
	board._compute_clues()
	return board


## 逆向删线索：从全翻开出发，逐步关闭格子（保持唯一解）。返回最终 givens。
func _prune_clues(board: Board, clue: int, constraint: int, mines: Array[Vector2i], cols: int, rows: int, deadline: int, constraint2: int = -1, clue2: int = -1) -> Array[Vector2i]:
	var gsize := board.grid.size()
	# 初始翻开集合 = 所有非雷格
	var revealed_set := {}
	var non_mine: Array[Vector2i] = []
	for r in gsize.y:
		for c in gsize.x:
			var pos := Vector2i(c, r)
			if not board.is_mine(pos):
				revealed_set[pos] = true
				non_mine.append(pos)

	var check := VariantConstraint.new(clue, constraint, _dominoes, constraint2, clue2)
	var check_callable := Callable(check, "check")
	var total := mines.size()
	var oracle := BruteForceOracle.new()

	# 启发式：优先删约束最弱的格（线索值接近值域中心），提升可解命中率、减少重试
	var center := float(ClueEngine.value_upper_bound(clue, Vector2i(cols, rows))) * 0.5
	var _b := board
	non_mine.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var va: Variant = _b.grid.get_cell(a).value
		var vb: Variant = _b.grid.get_cell(b).value
		var da: float = absf(float(va) - center) if va is int else center
		var db: float = absf(float(vb) - center) if vb is int else center
		if da != db:
			return da < db
		return a.y < b.y or (a.y == b.y and a.x < b.x)
	)

	for pos in non_mine:
		if Time.get_ticks_msec() > deadline:
			break
		revealed_set.erase(pos)  # 尝试关闭
		var constraints := _collect_constraints(board, revealed_set)
		# 计数型线索（classic/n4/sc/distsum）走内化剪枝计数（快）；其余线索型走变体回溯
		var cnt: int
		if clue2 >= 0:
			# E 类线索混合：两个线索窗口不同，无法内化剪枝，走通用变体回溯
			cnt = oracle.count_solutions_variant(Vector2i(cols, rows), constraints, total, check_callable, [], 2)
		elif clue == ClueEngine.Variant.CLASSIC:
			cnt = oracle.count_solutions_classic(Vector2i(cols, rows), constraints, total, constraint, _dominoes, [], 2, [], [], constraint2)
		elif clue == ClueEngine.Variant.N4:
			cnt = oracle.count_solutions_classic(Vector2i(cols, rows), constraints, total, constraint, _dominoes, [], 2, ClueEngine.orthogonal_dirs(), [], constraint2)
		elif clue == ClueEngine.Variant.SAME_COLOR:
			cnt = oracle.count_solutions_classic(Vector2i(cols, rows), constraints, total, constraint, _dominoes, [], 2, ClueEngine.diagonal_dirs(), [], constraint2)
		elif clue == ClueEngine.Variant.DIST_SUM:
			var dw := ClueEngine.dist_sum_dirs_weights()
			cnt = oracle.count_solutions_classic(Vector2i(cols, rows), constraints, total, constraint, _dominoes, [], 2, dw[0], dw[1], constraint2)
		else:
			cnt = oracle.count_solutions_variant(Vector2i(cols, rows), constraints, total, check_callable, [], 2)
		if cnt != 1:
			revealed_set[pos] = true  # 多解/无解/超限，撤销

	var givens: Array[Vector2i] = []
	for pos in revealed_set:
		givens.append(pos)
	return givens


## 从翻开集合构造玩家视角约束（绕过 cell.state，直接用 cell.value）。
func _collect_constraints(board: Board, revealed_set: Dictionary) -> Dictionary:
	var constraints := {}
	for pos in revealed_set:
		var cell := board.grid.get_cell(pos)
		if cell.value is Array:
			constraints[pos] = {"type": "equality_pair", "a": cell.value[0], "b": cell.value[1]}
		else:
			constraints[pos] = {"type": "equality", "value": cell.value}
	return constraints


## 选 mask_count 个「值 ≥1 的计数型线索格」遮蔽成 ? 格（interval [1, max] = 邻雷 ≥1）。
## 排除 Clock（方位语义）/ HV（双值）/ FR（射线）——它们的值不是「邻雷数」，遮蔽语义不成立。
func _select_masked(board: Board, givens: Array[Vector2i], mask_count: int) -> Dictionary:
	var masked := {}
	if mask_count <= 0:
		return masked
	if board.clue_variant in [ClueEngine.Variant.CLOCK, ClueEngine.Variant.HV, ClueEngine.Variant.FR]:
		return masked
	var candidates: Array[Vector2i] = []
	for g in givens:
		var cell := board.grid.get_cell(g)
		if cell.value is int and cell.value >= 1:
			candidates.append(g)
	# 随机（确定性 _rng）选 mask_count 个
	var hi: int = ClueEngine.value_upper_bound(board.clue_variant, board.grid.size())
	for i in mini(mask_count, candidates.size()):
		var j := _rng.randi_range(i, candidates.size() - 1)
		var t := candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = t
		masked[candidates[i]] = Vector2i(1, hi)
	return masked


## 从 givens 构造 level dict（revealed 只存坐标，线索值由 load 时重算；遮蔽格带 interval）。
func _build_level_from_givens(variant_code: String, rows: int, cols: int, mines: Array[Vector2i], givens: Array[Vector2i], masked: Dictionary = {}) -> Dictionary:
	var revealed: Array = []
	for g in givens:
		if masked.has(g):
			revealed.append({"r": g.y, "c": g.x, "interval": [masked[g].x, masked[g].y]})
		else:
			revealed.append({"r": g.y, "c": g.x})
	var mines_arr: Array = []
	for m in mines:
		mines_arr.append({"r": m.y, "c": m.x})
	return {
		"variant": variant_code,
		"size": {"rows": rows, "cols": cols},
		"total_mines": mines.size(),
		"mines": mines_arr,
		"revealed": revealed,
		"dominoes": _serialize_dominoes(_dominoes),
	}


## Fisher-Yates 原地打乱 Array[Vector2i]。
func _rng_shuffle_vec2i(arr: Array[Vector2i]) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t := arr[i]
		arr[i] = arr[j]
		arr[j] = t


# ============ 布雷策略 ============

var _dominoes: Array = []


func _place_mines(constraint: int, cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	match constraint:
		ConstraintEngine.Variant.MX:
			return _place_mx(cols, rows, mine_count)
		ConstraintEngine.Variant.QD:
			return _place_qd(cols, rows, mine_count)
		ConstraintEngine.Variant.DT:
			return _place_dt(cols, rows, mine_count)
		ConstraintEngine.Variant.EP:
			return _place_ep(cols, rows, mine_count)
		ConstraintEngine.Variant.FOUR_COLOR:
			return _place_4c(cols, rows, mine_count)
		ConstraintEngine.Variant.RL:
			return _place_rl(cols, rows, mine_count)
		ConstraintEngine.Variant.PF:
			return _place_pf(cols, rows, mine_count)
		_:
			return _place_random(cols, rows, mine_count)


## 双约束布雷：双向尝试（ca 主 + cb 副，再 cb 主 + ca 副），命中即返回（F 类双布局）。
func _place_mines_dual(ca: int, cb: int, cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	# 方向 1：ca 确定性布雷 + cb 验证
	for attempt in 200:
		var mines := _place_mines(ca, cols, rows, mine_count)
		if not mines.is_empty() and _satisfies(cb, mines, cols, rows):
			return mines
	# 方向 2：cb 确定性布雷 + ca 验证
	for attempt in 200:
		var mines := _place_mines(cb, cols, rows, mine_count)
		if not mines.is_empty() and _satisfies(ca, mines, cols, rows):
			return mines
	return []


## 判断雷分布是否满足某全局约束。
func _satisfies(constraint: int, mines: Array[Vector2i], cols: int, rows: int) -> bool:
	var ms := {}
	for m in mines:
		ms[m] = true
	return ConstraintEngine.check(constraint, ms, Vector2i(cols, rows), {"dominoes": _dominoes})


## 经典/无约束：随机布雷。
func _place_random(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for r in rows:
		for c in cols:
			cells.append(Vector2i(c, r))
	return _sample(cells, mine_count)


## G1 镜像：反推左半区(不含轴) k 个 + 轴列 j 个（2k+j = mine_count），确定性放置。
func _place_mx(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	var has_axis := (cols % 2 == 1)
	var left_cols := cols / 2  # 不含轴列的左半区列数（偶数=cols/2，奇数=(cols-1)/2）
	var left_cells: Array[Vector2i] = []
	var axis_cells: Array[Vector2i] = []
	for r in rows:
		for c in left_cols:
			left_cells.append(Vector2i(c, r))
		if has_axis:
			axis_cells.append(Vector2i(cols / 2, r))
	# 收集所有合法 (k, j)：2k + j = mine_count
	var options: Array = []
	var max_j: int = axis_cells.size() if has_axis else 0
	for j in range(max_j + 1):
		if j > mine_count:
			break
		var rem := mine_count - j
		if rem % 2 != 0:
			continue
		var k := rem / 2
		if k > left_cells.size():
			continue
		options.append([k, j])
	if options.is_empty():
		return []
	var pick: Array = options[_rng.randi_range(0, options.size() - 1)]
	var k: int = pick[0]
	var j: int = pick[1]
	var mines := {}
	for m in _sample(left_cells, k):
		mines[m] = true
		mines[Vector2i(cols - 1 - m.x, m.y)] = true
	for m in _sample(axis_cells, j):
		mines[m] = true
	return _dict_keys_vec2i(mines)


## G4 四象：四象限各 k 雷，中央行/列随机。先建象限划分，再反推 k。
func _place_qd(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	var mid_r := rows / 2
	var mid_c := cols / 2
	var cross: Array[Vector2i] = []
	var q_ul: Array[Vector2i] = []  # 左上
	var q_ur: Array[Vector2i] = []  # 右上
	var q_ll: Array[Vector2i] = []  # 左下
	var q_lr: Array[Vector2i] = []  # 右下
	for r in rows:
		for c in cols:
			var pos := Vector2i(c, r)
			if r == mid_r or c == mid_c:
				cross.append(pos)
			elif r < mid_r:
				if c < mid_c:
					q_ul.append(pos)
				else:
					q_ur.append(pos)
			else:
				if c < mid_c:
					q_ll.append(pos)
				else:
					q_lr.append(pos)
	# 每象限可容纳的雷数上限 = 最小象限格数（偶数尺寸四象限不对称，必须取最小）
	var q_max: int = q_ul.size()
	q_max = mini(q_max, q_ur.size())
	q_max = mini(q_max, q_ll.size())
	q_max = mini(q_max, q_lr.size())
	for k in range(q_max + 1):
		if 4 * k > mine_count:
			break
		var remaining := mine_count - 4 * k
		if remaining <= cross.size():
			var mines := {}
			for m in _sample(q_ul, k):
				mines[m] = true
			for m in _sample(q_ur, k):
				mines[m] = true
			for m in _sample(q_ll, k):
				mines[m] = true
			for m in _sample(q_lr, k):
				mines[m] = true
			for m in _sample(cross, remaining):
				mines[m] = true
			return _dict_keys_vec2i(mines)
	return []


## G5 骨牌：生成骨牌划分，每骨牌恰 1 雷。
func _place_dt(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	# 偶数尺寸无缝覆盖；奇数尺寸留 1 自由格
	var cells: Array[Vector2i] = []
	for r in rows:
		for c in cols:
			cells.append(Vector2i(c, r))
	# 贪心骨牌划分（水平优先）
	var used := {}
	var dominoes: Array = []
	for r in rows:
		for c in cols:
			var a := Vector2i(c, r)
			if used.has(a):
				continue
			var b := Vector2i(c + 1, r)
			if c + 1 < cols and not used.has(b):
				used[a] = true
				used[b] = true
				dominoes.append([a, b])
			else:
				var bv := Vector2i(c, r + 1)
				if r + 1 < rows and not used.has(bv):
					used[a] = true
					used[bv] = true
					dominoes.append([a, bv])
				else:
					used[a] = true  # 自由格
	if dominoes.size() < mine_count:
		return []
	_dominoes = _sample_dominoes(dominoes, mine_count)
	var mines: Array[Vector2i] = []
	for d in _dominoes:
		# 每骨牌随机选 1 格布雷
		mines.append(d[_rng.randi_range(0, 1)])
	return mines


func _sample_dominoes(dominoes: Array, k: int) -> Array:
	var idx: Array[int] = []
	for i in dominoes.size():
		idx.append(i)
	# Fisher-Yates
	for i in range(idx.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t := idx[i]
		idx[i] = idx[j]
		idx[j] = t
	var out: Array = []
	for i in k:
		out.append(dominoes[idx[i]])
	return out


## G6 端点平衡：最左/最右列各 k 雷，中间随机。
func _place_ep(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	if cols <= 1:
		return []
	for k in range(rows + 1):
		if 2 * k > mine_count:
			break
		var middle: Array[Vector2i] = []
		for r in rows:
			for c in range(1, cols - 1):
				middle.append(Vector2i(c, r))
		var remaining := mine_count - 2 * k
		if remaining <= middle.size():
			var mines := {}
			for r in _sample(_col_cells(0, rows), k):
				mines[r] = true
			for r in _sample(_col_cells(cols - 1, rows), k):
				mines[r] = true
			for m in _sample(middle, remaining):
				mines[m] = true
			return _dict_keys_vec2i(mines)
	return []


## G7 四色：黑白各 k 雷。
func _place_4c(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	if mine_count % 2 != 0:
		return []  # 总雷数必须为偶数
	var k := mine_count / 2
	var black: Array[Vector2i] = []
	var white: Array[Vector2i] = []
	for r in rows:
		for c in cols:
			if (c + r) % 2 == 0:
				black.append(Vector2i(c, r))
			else:
				white.append(Vector2i(c, r))
	if black.size() < k or white.size() < k:
		return []
	var mines := {}
	for m in _sample(black, k):
		mines[m] = true
	for m in _sample(white, k):
		mines[m] = true
	return _dict_keys_vec2i(mines)


## G2 相邻行锁：DFS 构造行雷数序列（每步 ±1，总和 = mine_count），再逐行布雷。
func _place_rl(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	for _try in 50:
		var seq: Array[int] = []
		seq.resize(rows)
		if _rl_dfs(seq, 0, cols, rows, mine_count, 0):
			var mines := {}
			for r in rows:
				var row_cells: Array[Vector2i] = []
				for c in cols:
					row_cells.append(Vector2i(c, r))
				for m in _sample(row_cells, seq[r]):
					mines[m] = true
			return _dict_keys_vec2i(mines)
	return []


## DFS 构造行序列（带上下界剪枝）。seq[r] 待填，cur_sum 为前 r 行总和。
func _rl_dfs(seq: Array[int], r: int, cols: int, rows: int, target: int, cur_sum: int) -> bool:
	if r == rows:
		return cur_sum == target
	var rem_rows := rows - r - 1
	var cands: Array[int] = []
	if r == 0:
		for v in range(cols + 1):
			cands.append(v)
	else:
		for d: int in [-1, 1]:
			var v: int = seq[r - 1] + d
			if v >= 0 and v <= cols:
				cands.append(v)
	# 随机打乱候选，增加多样性
	for i in range(cands.size() - 1, 0, -1):
		var jj := _rng.randi_range(0, i)
		var t := cands[i]
		cands[i] = cands[jj]
		cands[jj] = t
	for v in cands:
		var rem_need: int = target - cur_sum - v
		if rem_need < 0 or rem_need > rem_rows * cols:
			continue
		seq[r] = v
		if _rl_dfs(seq, r + 1, cols, rows, target, cur_sum + v):
			return true
	return false


## G3 局部禁形：随机布雷 + 2×2 过滤。
func _place_pf(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	for _attempt in 300:
		var mines := _place_random(cols, rows, mine_count)
		var ms := {}
		for m in mines:
			ms[m] = true
		if ConstraintEngine.check(ConstraintEngine.Variant.PF, ms, Vector2i(cols, rows)):
			return mines
	return []


# ============ 工具 ============

## Dictionary(Vector2i -> bool) 转 Array[Vector2i]（Dictionary.keys() 返回无类型 Array，需显式转换）。
func _dict_keys_vec2i(d: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for k in d:
		out.append(k)
	return out


## 骨牌划分序列化（Array[Array[Vector2i]] → [[{r,c},{r,c}], ...]），供 DT 关卡 JSON 落盘。
func _serialize_dominoes(dom: Array) -> Array:
	var out: Array = []
	for d in dom:
		var pair: Array = []
		for p in d:
			pair.append({"r": p.y, "c": p.x})
		out.append(pair)
	return out


func _col_cells(col: int, rows: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for r in rows:
		out.append(Vector2i(col, r))
	return out


## Fisher-Yates 采样 k 个（不重复）。
func _sample(cells: Array[Vector2i], k: int) -> Array[Vector2i]:
	if k <= 0:
		return []
	if k > cells.size():
		return []
	var idx: Array[int] = []
	for i in cells.size():
		idx.append(i)
	for i in range(idx.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t := idx[i]
		idx[i] = idx[j]
		idx[j] = t
	var out: Array[Vector2i] = []
	for i in k:
		out.append(cells[idx[i]])
	return out


## 选单点开局：线索值 == minimal_clue_value 的安全格，优先扩散面积最大者。
## 扩散面积越大 → 初始线索越充分 → 纯逻辑可解命中率越高（第三篇 P0 优化）。
## 选 K 个「非零线索」格作为初始线索（K ∈ [MIN_OPENING_AREA, MAX_OPENING_AREA]）。
## 对齐手工关卡：给少量数字格线索让玩家推理，而非 0 格扩散全翻开（难度归零）。
func _pick_openings(board: Board) -> Array[Vector2i]:
	var gsize := board.grid.size()
	var candidates: Array[Vector2i] = []
	for r in gsize.y:
		for c in gsize.x:
			var pos := Vector2i(c, r)
			var cell := board.grid.get_cell(pos)
			if cell.is_mine:
				continue
			# 排除「无信息 0 格」：0 格翻开会连锁扩散，导致开局全翻开（难度归零）
			if cell.value is int and cell.value == 0:
				continue
			candidates.append(pos)
	if candidates.is_empty():
		return []
	_shuffle(candidates)
	var k := _rng.randi_range(MIN_OPENING_AREA, MAX_OPENING_AREA)
	k = mini(k, candidates.size())
	return candidates.slice(0, k)


## 确定性洗牌（用 _rng，保证同 seed 可复现）。
func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## 计算翻开 pos 后的连锁扩散格数（含 pos；0 格继续扩散，边界数字格计入）。
func _reveal_area(board: Board, pos: Vector2i) -> int:
	var stack: Array[Vector2i] = [pos]
	var visited := {}
	var count := 0
	while not stack.is_empty():
		var p: Vector2i = stack.pop_back()
		if visited.has(p):
			continue
		visited[p] = true
		var cell := board.grid.get_cell(p)
		if cell.is_mine:
			continue
		count += 1
		if cell.is_zero_clue():
			for nb in board.grid.get_neighbors(p):
				if not visited.has(nb):
					stack.append(nb)
	return count


func _build_level(variant_code: String, rows: int, cols: int, mines: Array[Vector2i], board: Board) -> Dictionary:
	var revealed: Array = []
	# 收集 settle 后所有已翻开格（含连锁扩散）
	var gsize := board.grid.size()
	for r in gsize.y:
		for c in gsize.x:
			var pos := Vector2i(c, r)
			var cell := board.grid.get_cell(pos)
			if cell.state == Cell.State.REVEALED:
				var val: Variant = cell.value
				revealed.append({"r": r, "c": c, "value": val})
	var mines_arr: Array = []
	for m in mines:
		mines_arr.append({"r": m.y, "c": m.x})
	return {
		"variant": variant_code,
		"size": {"rows": rows, "cols": cols},
		"total_mines": mines.size(),
		"mines": mines_arr,
		"revealed": revealed,
		"dominoes": _serialize_dominoes(_dominoes),
	}
