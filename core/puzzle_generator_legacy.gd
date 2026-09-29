# puzzle_generator_legacy.gd —— 旧管线（遗产）：内置变体枚举的旧实现 + 旧布雷策略。
# 2026-09 拆分：从 puzzle_generator.gd 移出，隔离「内置变体枚举」遗产代码。
# 仅服务 archive/tools 与集成测试；生产一律走 PuzzleGenerator.generate_with_rules（规则平台）。
# 新增能力请扩展规则平台，不要再扩展本文件。
class_name PuzzleGeneratorLegacy
extends RefCounted

var _rng := RandomNumberGenerator.new()
var _dominoes: Array = []


## 旧构造式实现（E 类线索混合 clue2≥0 时由 PuzzleGenerator.generate_constructive 委托）。
func generate_impl(clue: int, constraint: int, variant_code: String, size: Vector2i, mine_count: int, seed: int, mask_count: int) -> Dictionary:
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
			push_warning("PuzzleGeneratorLegacy: 构造式生成超时 %s" % variant_code)
			return {}

		# 1. 确定性布雷（满足全局约束）
		var mines := place_mines(constraint, cols, rows, mine_count)
		if mines.is_empty():
			continue

		# 2. 建棋盘 + 计算线索
		var board := make_board(clue, constraint, mines, cols, rows)

		# 3. 逆向删线索（保持唯一解）
		var givens := prune_clues(board, clue, constraint, mines, cols, rows, deadline)
		if givens.is_empty():
			continue

		# 3.5 遮蔽：选 mask_count 个「值 ≥1」的 given 变成 ? 格（interval 约束，弱化线索）
		var masked := select_masked(board, givens, mask_count)

		# 4. 纯逻辑可解验证（settle：翻开 givens 触发连锁扩散；遮蔽格先设 interval 再 reveal）
		var play_board := make_board(clue, constraint, mines, cols, rows)
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
		return build_level_from_givens(variant_code, rows, cols, mines, givens, masked)

	return {}


## 旧 DT 双布局实现（PuzzleGenerator.generate_dual 的 DT 分支委托）。
func generate_dual_impl(ca: int, cb: int, code: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
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
			push_warning("PuzzleGeneratorLegacy: 双布局生成超时 %s" % code)
			return {}

		var mines := place_mines_dual(ca, cb, cols, rows, mine_count)
		if mines.is_empty():
			continue

		var board := make_board(ClueEngine.Variant.CLASSIC, ca, mines, cols, rows, cb)
		var givens := prune_clues(board, ClueEngine.Variant.CLASSIC, ca, mines, cols, rows, deadline, cb)
		if givens.is_empty():
			continue

		var play_board := make_board(ClueEngine.Variant.CLASSIC, ca, mines, cols, rows, cb)
		for g in givens:
			play_board.reveal(g)
		if play_board.state == Board.GameState.WON:
			continue
		var check := VariantConstraint.new(ClueEngine.Variant.CLASSIC, ca, _dominoes, cb)
		var player := SolverPerfectPlayer.new()
		var result := player.solve(play_board, Callable(check, "check"))
		if not result[0]:
			continue

		return build_level_from_givens(code, rows, cols, mines, givens, {})

	return {}


## 旧 E 类线索混合实现（PuzzleGenerator.generate_mixed_clue 委托）。
func generate_impl_clue2(c1: int, c2: int, code: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
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
			push_warning("PuzzleGeneratorLegacy: 线索混合生成超时 %s" % code)
			return {}

		var mines := place_random(cols, rows, mine_count)
		if mines.is_empty():
			continue

		var board := make_board(c1, -1, mines, cols, rows, -1, c2)
		var givens := prune_clues(board, c1, -1, mines, cols, rows, deadline, -1, c2)
		if givens.is_empty():
			continue

		var play_board := make_board(c1, -1, mines, cols, rows, -1, c2)
		for g in givens:
			play_board.reveal(g)
		if play_board.state == Board.GameState.WON:
			continue
		var check := VariantConstraint.new(c1, -1, _dominoes, -1, c2)
		var player := SolverPerfectPlayer.new()
		var result := player.solve(play_board, Callable(check, "check"))
		if not result[0]:
			continue

		return build_level_from_givens(code, rows, cols, mines, givens, {})

	return {}


## 建棋盘 + 布雷 + 计算线索。constraint2 为双布局第二约束；clue2 为线索混合第二线索型。
func make_board(clue: int, constraint: int, mines: Array[Vector2i], cols: int, rows: int, constraint2: int = -1, clue2: int = -1) -> Board:
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
func prune_clues(board: Board, clue: int, constraint: int, mines: Array[Vector2i], cols: int, rows: int, deadline: int, constraint2: int = -1, clue2: int = -1) -> Array[Vector2i]:
	var gsize := board.grid.size()
	# 初始翻开集合 = 所有非雷格，但排除 0 值格（0 格显示空白、玩家翻开才扩散，不是线索）
	var revealed_set := {}
	var non_mine: Array[Vector2i] = []
	for r in gsize.y:
		for c in gsize.x:
			var pos := Vector2i(c, r)
			if board.is_mine(pos):
				continue
			var cell := board.grid.get_cell(pos)
			if cell.value is int and int(cell.value) == 0:
				continue
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
		var constraints := collect_constraints(board, revealed_set)
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
func collect_constraints(board: Board, revealed_set: Dictionary) -> Dictionary:
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
func select_masked(board: Board, givens: Array[Vector2i], mask_count: int) -> Dictionary:
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
func build_level_from_givens(variant_code: String, rows: int, cols: int, mines: Array[Vector2i], givens: Array[Vector2i], masked: Dictionary = {}) -> Dictionary:
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
		"dominoes": serialize_dominoes(_dominoes),
	}


## Fisher-Yates 原地打乱 Array[Vector2i]。
func rng_shuffle_vec2i(arr: Array[Vector2i]) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t := arr[i]
		arr[i] = arr[j]
		arr[j] = t


# ============ 布雷策略 ============

func place_mines(constraint: int, cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	match constraint:
		ConstraintEngine.Variant.MX:
			return place_mx(cols, rows, mine_count)
		ConstraintEngine.Variant.QD:
			return place_qd(cols, rows, mine_count)
		ConstraintEngine.Variant.DT:
			return place_dt(cols, rows, mine_count)
		ConstraintEngine.Variant.EP:
			return place_ep(cols, rows, mine_count)
		ConstraintEngine.Variant.FOUR_COLOR:
			return place_4c(cols, rows, mine_count)
		ConstraintEngine.Variant.RL:
			return place_rl(cols, rows, mine_count)
		ConstraintEngine.Variant.PF:
			return place_pf(cols, rows, mine_count)
		_:
			return place_random(cols, rows, mine_count)


## 双约束布雷：双向尝试（ca 主 + cb 副，再 cb 主 + ca 副），命中即返回（F 类双布局）。
func place_mines_dual(ca: int, cb: int, cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	# 方向 1：ca 确定性布雷 + cb 验证
	for attempt in 200:
		var mines := place_mines(ca, cols, rows, mine_count)
		if not mines.is_empty() and satisfies(cb, mines, cols, rows):
			return mines
	# 方向 2：cb 确定性布雷 + ca 验证
	for attempt in 200:
		var mines := place_mines(cb, cols, rows, mine_count)
		if not mines.is_empty() and satisfies(ca, mines, cols, rows):
			return mines
	return []


## 判断雷分布是否满足某全局约束。
func satisfies(constraint: int, mines: Array[Vector2i], cols: int, rows: int) -> bool:
	var ms := {}
	for m in mines:
		ms[m] = true
	return ConstraintEngine.check(constraint, ms, Vector2i(cols, rows), {"dominoes": _dominoes})


## 经典/无约束：随机布雷。
func place_random(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for r in rows:
		for c in cols:
			cells.append(Vector2i(c, r))
	return sample(cells, mine_count)


## G1 镜像：反推左半区(不含轴) k 个 + 轴列 j 个（2k+j = mine_count），确定性放置。
func place_mx(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	var has_axis := (cols % 2 == 1)
	var left_cols := floori(cols / 2.0)  # 不含轴列的左半区列数（偶数=cols/2，奇数=(cols-1)/2）｜A8：int/int 显式化
	var left_cells: Array[Vector2i] = []
	var axis_cells: Array[Vector2i] = []
	for r in rows:
		for c in left_cols:
			left_cells.append(Vector2i(c, r))
		if has_axis:
			axis_cells.append(Vector2i(floori(cols / 2.0), r))   # A8：int/int 显式化
	# 收集所有合法 (k, j)：2k + j = mine_count
	var options: Array = []
	var max_j: int = axis_cells.size() if has_axis else 0
	for j in range(max_j + 1):
		if j > mine_count:
			break
		var rem := mine_count - j
		if rem % 2 != 0:
			continue
		var pairs := floori(rem / 2.0)   # A8：int/int 显式化（rem 恒 ≥0）
		if pairs > left_cells.size():
			continue
		options.append([pairs, j])
	if options.is_empty():
		return []
	var pick: Array = options[_rng.randi_range(0, options.size() - 1)]
	var k: int = pick[0]
	var j: int = pick[1]
	var mines := {}
	for m in sample(left_cells, k):
		mines[m] = true
		mines[Vector2i(cols - 1 - m.x, m.y)] = true
	for m in sample(axis_cells, j):
		mines[m] = true
	return dict_keys_vec2i(mines)


## G4 四象：委托规则平台的 QdRule.place_mines（单一实现）。
## 不再在生成器里手写第二份象限划分——与规则平台共用同一份布雷逻辑，避免两套漂移
##（历史上生成器与 QdRule 各写一遍，偶数盘语义曾不一致：布雷放中轴、校验算右下）。
func place_qd(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	var qd = RuleRegistry.default().resolve(&"qd")
	if qd == null:
		return []
	return qd.place_mines(_rng, cols, rows, mine_count)


## G5 骨牌：生成骨牌划分，每骨牌恰 1 雷。
func place_dt(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
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
	_dominoes = sample_dominoes(dominoes, mine_count)
	var mines: Array[Vector2i] = []
	for d in _dominoes:
		# 每骨牌随机选 1 格布雷
		mines.append(d[_rng.randi_range(0, 1)])
	return mines


func sample_dominoes(dominoes: Array, k: int) -> Array:
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
func place_ep(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
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
			for r in sample(col_cells(0, rows), k):
				mines[r] = true
			for r in sample(col_cells(cols - 1, rows), k):
				mines[r] = true
			for m in sample(middle, remaining):
				mines[m] = true
			return dict_keys_vec2i(mines)
	return []


## G7 四色：黑白各 k 雷。
func place_4c(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	if mine_count % 2 != 0:
		return []  # 总雷数必须为偶数
	var k := floori(mine_count / 2.0)   # A8：int/int 显式化
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
	for m in sample(black, k):
		mines[m] = true
	for m in sample(white, k):
		mines[m] = true
	return dict_keys_vec2i(mines)


## G2 相邻行锁：DFS 构造行雷数序列（每步 ±1，总和 = mine_count），再逐行布雷。
func place_rl(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	for _try in 50:
		var seq: Array[int] = []
		seq.resize(rows)
		if rl_dfs(seq, 0, cols, rows, mine_count, 0):
			var mines := {}
			for r in rows:
				var row_cells: Array[Vector2i] = []
				for c in cols:
					row_cells.append(Vector2i(c, r))
				for m in sample(row_cells, seq[r]):
					mines[m] = true
			return dict_keys_vec2i(mines)
	return []


## DFS 构造行序列（带上下界剪枝）。seq[r] 待填，cur_sum 为前 r 行总和。
func rl_dfs(seq: Array[int], r: int, cols: int, rows: int, target: int, cur_sum: int) -> bool:
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
		if rl_dfs(seq, r + 1, cols, rows, target, cur_sum + v):
			return true
	return false


## G3 局部禁形：随机布雷 + 2×2 过滤。
func place_pf(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	for _attempt in 300:
		var mines := place_random(cols, rows, mine_count)
		var ms := {}
		for m in mines:
			ms[m] = true
		if ConstraintEngine.check(ConstraintEngine.Variant.PF, ms, Vector2i(cols, rows)):
			return mines
	return []


# ============ 工具 ============

## Dictionary(Vector2i -> bool) 转 Array[Vector2i]（Dictionary.keys() 返回无类型 Array，需显式转换）。
func dict_keys_vec2i(d: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for k in d:
		out.append(k)
	return out


## 骨牌划分序列化（Array[Array[Vector2i]] → [[{r,c},{r,c}], ...]），供 DT 关卡 JSON 落盘。
func serialize_dominoes(dom: Array) -> Array:
	var out: Array = []
	for d in dom:
		var pair: Array = []
		for p in d:
			pair.append({"r": p.y, "c": p.x})
		out.append(pair)
	return out


func col_cells(col: int, rows: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for r in rows:
		out.append(Vector2i(col, r))
	return out


## Fisher-Yates 采样 k 个（不重复）。
func sample(cells: Array[Vector2i], k: int) -> Array[Vector2i]:
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
