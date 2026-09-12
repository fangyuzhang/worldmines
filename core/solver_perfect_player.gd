# solver_perfect_player.gd —— 完美玩家模拟器（文档 §4.4 test_levels_solvable 的种子）
# 逐轮查 Oracle（带总雷数/剩余雷数计数器），每步必须存在可确定的必安全格或必雷格，
# 卡死即关卡失败。供测试与生成器复用。
#
# ⚠️ 遗留路径：本类走 **BruteForceOracle 穷举回溯**（check 回调），供遗留生成器
# （puzzle_generator_legacy.gd）使用。**规则关卡的序贯可解性已统一走 CP-SAT 路径**：
#   - `ProofLog.build()`   —— 玩家视角 + HintSolver（CP-SAT）+ 确证雷不动点（canonical，落盘用）
#   - `PuzzleGenerator._solve_rules_stepwise()` —— 生成器内部 CP-SAT 强制格循环（带难度统计）
# 三处看似同构但**演绎源不同**（穷举回溯 vs CP-SAT），勿强行合并；改动须三处同步核对。
class_name SolverPerfectPlayer
extends RefCounted

var oracle := BruteForceOracle.new()


## 完美玩家模拟。返回 [是否可解, 步数]。
## board 已加载关卡（含初始翻开格）；check 为约束检查回调。
## timeout_ms > 0 时启用墙钟保护：单次 oracle 查询可能组合爆炸，
## 步数上限拦不住「一步算很久」，必须由墙钟兜底（否则生成器 deadline 形同虚设）。
func solve(board: Board, check: Callable, timeout_ms: int = 0) -> Array:
	var gsize := board.grid.size()
	var total := board.total_mines
	var known_mines: Array[Vector2i] = []
	var steps := 0
	var deadline := Time.get_ticks_msec() + timeout_ms if timeout_ms > 0 else 0

	while true:
		if board.state == Board.GameState.WON:
			return [true, steps]
		if board.state == Board.GameState.LOST:
			return [false, steps]
		if steps > gsize.x * gsize.y * 12:
			return [false, steps]
		if timeout_ms > 0 and Time.get_ticks_msec() > deadline:
			return [false, steps]

		var revealed := _collect_revealed(board)
		var remaining := total - known_mines.size()

		# 计数型线索（classic/n4/sc/distsum）走内化剪枝快路径；全局约束型给 classic 快路径加 leaf_check；其余走通用变体回溯
		var verdict := {}
		if board.rule_clue_id != "":
			# 自举式规则关卡：线索窗口由规则自定义（如「骑士」与 8 邻完全不同），
			# 内置变体分支不适用，必须走通用回溯（check 由 RuleOracle 提供）。
			# 此前会误落到 CLASSIC 快路径 → 无猜验证口径错误。
			verdict = oracle.query_variant(gsize, revealed, remaining, check, known_mines)
		elif board.clue_variant2 >= 0:
			# E 类线索混合：两个线索窗口不同，走通用变体回溯（check 回调同时校验两个线索）
			verdict = oracle.query_variant(gsize, revealed, remaining, check, known_mines)
		else:
			match board.clue_variant:
				ClueEngine.Variant.CLASSIC:
					verdict = oracle.query(gsize, revealed, remaining, check, known_mines, [], board.constraint_variant, board.dominoes, [], board.constraint_variant2)
				ClueEngine.Variant.N4:
					verdict = oracle.query(gsize, revealed, remaining, check, known_mines, ClueEngine.orthogonal_dirs())
				ClueEngine.Variant.SAME_COLOR:
					verdict = oracle.query(gsize, revealed, remaining, check, known_mines, ClueEngine.diagonal_dirs())
				ClueEngine.Variant.DIST_SUM:
					var dw := ClueEngine.dist_sum_dirs_weights()
					verdict = oracle.query(gsize, revealed, remaining, check, known_mines, dw[0], -1, [], dw[1])
				_:
					verdict = oracle.query_variant(gsize, revealed, remaining, check, known_mines)

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
			return [false, steps]  # 卡死

		for p in safe:
			board.reveal(p)
		for m in mine:
			known_mines.append(m)
		steps += 1
	return [false, steps]  # 不可达，满足编译器


## 收集当前玩家视角约束集：已翻开格 -> constraint_dict。
func _collect_revealed(board: Board) -> Dictionary:
	var revealed := {}
	# 用 all_positions()（v2.9.3）：AdjacencyGrid.size() 是包围盒，
	# 按 size 双重循环会把洞格 get_cell()==null 当 Cell 用而报错（异形生成路径）。
	for pos in board.grid.all_positions():
		var cell := board.grid.get_cell(pos)
		if cell != null and cell.state == Cell.State.REVEALED:
			revealed[pos] = board.get_player_constraint(pos)
	return revealed
