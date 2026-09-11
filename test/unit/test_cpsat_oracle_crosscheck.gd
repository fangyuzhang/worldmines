extends GutTest

## CP-SAT 生产求解器 vs 穷举裁判 的 3×3 全枚举对拍（验证资产 ⑤ 跨实现一致性 + ⑥ 3×3 黄金标准）
##
## 背景：`test_oracle_3x3.gd` 只对拍**旧传播器**（SolverBasic）vs BruteForceOracle，
## 生产路径 `RuleCpSat.find_forced_cells`（C# CP-SAT）却没有穷举黄金标准对拍。
## 这很危险——刚修掉的「未引用格剪枝」bug 正是只有这种对拍能抓住：
## CP-SAT 报「模型数=1（唯一解）却推不出任何 forced 格」，而穷举裁判会给出正确结论。
##
## 断言是**双向相等**（不是 ⊆）：
##   · CP-SAT 说 forced 但穷举说不 forced → 不可靠（soundness 违约）
##   · 穷举说 forced 但 CP-SAT 没给出 → 遗漏（completeness 违约，即上面的 bug）
## 两个方向都必须为零。


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


func test_cpsat_matches_exhaustive_oracle() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return

	var clue_rule: Object = RuleRegistry.default().resolve(&"classic")
	assert_true(clue_rule != null, "classic 规则应已注册")
	if clue_rule == null:
		return

	var all_cells: Array[Vector2i] = []
	for r in 3:
		for c in 3:
			all_cells.append(Vector2i(c, r))

	var oracle := BruteForceOracle.new()
	var checked := 0
	var sound_violations := 0   # CP-SAT 说 forced，穷举不认
	var completeness_violations := 0  # 穷举说 forced，CP-SAT 漏了

	for mask in 512:
		var mines: Array[Vector2i] = []
		for i in 9:
			if (mask >> i) & 1:
				mines.append(all_cells[i])
		var non_mine: Array[Vector2i] = []
		for p in all_cells:
			if not mines.has(p):
				non_mine.append(p)
		# 两个翻开场景：不翻开 / 翻开第一个非雷格
		var scenes: Array[Array] = [[]]
		if non_mine.size() >= 1:
			var s1: Array[Vector2i] = [non_mine[0]]
			scenes.append(s1)

		for scene in scenes:
			var board := _make_board(mines, scene)
			var revealed := {}
			var active := {}
			for r in 3:
				for c in 3:
					var pos := Vector2i(c, r)
					var cell := board.grid.get_cell(pos)
					if cell.state == Cell.State.REVEALED:
						var con := board.get_player_constraint(pos)
						revealed[pos] = con
						if str(con.get("type", "")) == "equality":
							active[pos] = con["value"]

			# 穷举裁判（完备，权威）
			var exhaustive: Dictionary = oracle.query(Vector2i(3, 3), revealed, mines.size(), ClassicConstraint.check)
			if exhaustive.is_empty():
				continue  # 该场景无一致雷分布

			# CP-SAT 生产路径
			var rule_oracle := RuleOracle.new(clue_rule, [], Vector2i(3, 3), mines.size(), null)
			var spec := rule_oracle.build_spec(active, [], {})
			var forced: Dictionary = RuleCpSat.find_forced_cells(spec)
			var cpsat_safe := {}
			var cpsat_mine := {}
			for s in forced.get("safe", []):
				cpsat_safe[Vector2i(int(s[1]), int(s[0]))] = true
			for m in forced.get("mine", []):
				cpsat_mine[Vector2i(int(m[1]), int(m[0]))] = true

			for p in all_cells:
				if active.has(p):
					continue  # 已翻开格：穷举裁判会标 safe，但那是「既定事实」而非「强制结论」。
					# find_forced_cells 只报告自由格的强制结论，二者口径不同，必须跳过。
				var ver: String = str(exhaustive.get(p, "uncertain"))
				var cs_safe: bool = cpsat_safe.has(p)
				var cs_mine: bool = cpsat_mine.has(p)
				checked += 1
				if cs_safe and ver != "safe":
					sound_violations += 1
					gut.p("  sound违约 mask=%d (%d,%d) 穷举=%s" % [mask, p.x, p.y, ver])
				if cs_mine and ver != "mine":
					sound_violations += 1
					gut.p("  sound违约 mask=%d (%d,%d) 穷举=%s" % [mask, p.x, p.y, ver])
				if ver == "safe" and not cs_safe:
					completeness_violations += 1
					gut.p("  complete违约 mask=%d (%d,%d) 穷举=safe CP-SAT漏" % [mask, p.x, p.y])
				if ver == "mine" and not cs_mine:
					completeness_violations += 1
					gut.p("  complete违约 mask=%d (%d,%d) 穷举=mine CP-SAT漏" % [mask, p.x, p.y])

	assert_gt(checked, 0, "应至少对拍了若干格")
	assert_eq(sound_violations, 0, "CP-SAT 不得给出穷举裁判不认的 forced 结论")
	assert_eq(completeness_violations, 0, "CP-SAT 不得遗漏穷举裁判给出的 forced 结论")
