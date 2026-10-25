# solver_perfect_player.gd —— 完美玩家模拟器（文档 §4.4 test_levels_solvable 的种子）
# 逐轮查 Oracle（带总雷数/剩余雷数计数器），每步必须存在可确定的必安全格或必雷格，
# 卡死即关卡失败。供测试与生成器复用。
class_name SolverPerfectPlayer
extends RefCounted

var oracle := BruteForceOracle.new()


## 完美玩家模拟。返回 [是否可解, 步数]。
## board 已加载关卡（含初始翻开格）；check 为约束检查回调。
func solve(board: Board, check: Callable) -> Array:
	var gsize := board.grid.size()
	var total := board.total_mines
	var known_mines: Array[Vector2i] = []
	var steps := 0

	while true:
		if board.state == Board.GameState.WON:
			return [true, steps]
		if board.state == Board.GameState.LOST:
			return [false, steps]
		if steps > gsize.x * gsize.y * 12:
			return [false, steps]

		var revealed := _collect_revealed(board)
		var remaining := total - known_mines.size()

		# 计数型线索（classic/n4/sc/distsum）走内化剪枝快路径；全局约束型给 classic 快路径加 leaf_check；其余走通用变体回溯
		var verdict := {}
		if board.clue_variant2 >= 0:
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
	var gsize := board.grid.size()
	for r in gsize.y:
		for c in gsize.x:
			var pos := Vector2i(c, r)
			var cell := board.grid.get_cell(pos)
			if cell.state == Cell.State.REVEALED:
				revealed[pos] = board.get_player_constraint(pos)
	return revealed
