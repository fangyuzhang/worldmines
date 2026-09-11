# test_oracle_3x3.gd —— 传播器 ⊆ Oracle（文档 §4.4 / §5.2）
# 3×3 全枚举（2^9 = 512 种雷分布）× 若干翻开场景：
# SolverBasic 传播器结论必须 ⊆ BruteForceOracle 结论，100% 一致（不矛盾、不超范围）。
extends GutTest

var _oracle := BruteForceOracle.new()
var _solver := SolverBasic.new()


## 从 3×3 雷位集合构造一个 Board，并翻开指定格。
func _make_board(mines: Array[Vector2i], to_reveal: Array) -> Board:
	var board := Board.new()
	var grid := RectGrid.new()
	grid.setup(3, 3)
	board.grid = grid
	board.total_mines = mines.size()
	board._static_mines = mines.duplicate()
	for m in mines:
		grid.get_cell(m).is_mine = true
	board._compute_clues()
	for p in to_reveal:
		if not board.is_mine(p):
			board.reveal(p)
	return board


func test_propagator_subset_of_oracle() -> void:
	var all_cells: Array[Vector2i] = []
	for r in 3:
		for c in 3:
			all_cells.append(Vector2i(c, r))

	var checked := 0
	var mismatches := 0
	# 枚举 512 种雷分布
	for mask in 512:
		var mines: Array[Vector2i] = []
		for i in 9:
			if (mask >> i) & 1:
				mines.append(all_cells[i])
		# 对每种雷分布，试若干翻开场景（翻开 0~3 个非雷格）
		var non_mine: Array[Vector2i] = []
		for p in all_cells:
			if not mines.has(p):
				non_mine.append(p)
		var scenes: Array[Array] = [[]]
		if non_mine.size() >= 1:
			var s1: Array[Vector2i] = [non_mine[0]]
			scenes.append(s1)
		if non_mine.size() >= 2:
			var s2: Array[Vector2i] = [non_mine[0], non_mine[1]]
			scenes.append(s2)

		for scene in scenes:
			var board := _make_board(mines, scene)
			var revealed := {}
			var gsize := board.grid.size()
			for r in gsize.y:
				for c in gsize.x:
					var pos := Vector2i(c, r)
					var cell := board.grid.get_cell(pos)
					if cell.state == Cell.State.REVEALED:
						revealed[pos] = board.get_player_constraint(pos)

			var oracle_verdict := _oracle.query(Vector2i(3, 3), revealed, mines.size(), ClassicConstraint.check)
			if oracle_verdict.is_empty():
				continue  # 该场景无解（无一致雷分布），跳过
			var prop := _solver.propagate(board)

			# 传播器说 safe 的，Oracle 必须也是 safe
			for p in prop["safe"]:
				checked += 1
				if oracle_verdict.get(p) != "safe":
					mismatches += 1
					gut.p("  矛盾 safe mask=%d %s -> Oracle=%s" % [mask, p, oracle_verdict.get(p)])
			# 传播器说 mine 的，Oracle 必须也是 mine
			for p in prop["mine"]:
				checked += 1
				if oracle_verdict.get(p) != "mine":
					mismatches += 1
					gut.p("  矛盾 mine mask=%d %s -> Oracle=%s" % [mask, p, oracle_verdict.get(p)])

	assert_gt(checked, 0, "应至少验证了若干传播器结论")
	assert_eq(mismatches, 0, "传播器结论应 ⊆ Oracle 结论（%d 条结论全部一致）" % checked)
