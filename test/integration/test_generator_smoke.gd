# test_generator_smoke.gd —— 生成器约束布雷冒烟测试（文档第三篇 P0）
# 聚焦约束布雷确定性化：直接测布雷函数，快速、不触发 Oracle 完整验证。
extends GutTest


func test_constraint_placement_deterministic() -> void:
	var gen := PuzzleGenerator.new()
	# 旧布雷策略已随 PuzzleGeneratorLegacy 拆出（2026-09），经 gen._legacy 访问
	var legacy: Object = gen._legacy
	legacy._rng.seed = 12345
	# 约束 -> [cols, rows, mines]
	var cases := {
		ConstraintEngine.Variant.MX: [7, 7, 14],
		ConstraintEngine.Variant.RL: [5, 5, 6],
		ConstraintEngine.Variant.PF: [5, 5, 6],
		ConstraintEngine.Variant.QD: [5, 5, 6],
		ConstraintEngine.Variant.DT: [6, 6, 10],
		ConstraintEngine.Variant.EP: [7, 7, 10],
		ConstraintEngine.Variant.FOUR_COLOR: [6, 6, 10],
	}
	for constraint in cases:
		var spec: Array = cases[constraint]
		var cols: int = spec[0]
		var rows: int = spec[1]
		var mines: int = spec[2]
		var placed: Array = legacy.place_mines(constraint, cols, rows, mines)
		assert_false(placed.is_empty(), "约束 %d 布雷应非空" % constraint)
		if placed.is_empty():
			continue
		assert_eq(placed.size(), mines, "约束 %d 雷数应一致（%d）" % [constraint, placed.size()])
		var mine_set := {}
		for m in placed:
			mine_set[m] = true
		var extra := {}
		if constraint == ConstraintEngine.Variant.DT:
			extra = {"dominoes": legacy._dominoes}
		assert_true(ConstraintEngine.check(constraint, mine_set, Vector2i(cols, rows), extra), "约束 %d 布雷应满足约束" % constraint)
