# test_generator_constructive.gd —— 构造式生成测试（文档第三篇 P0）
# 验证构造式生成：非空、唯一解、纯逻辑可解。
extends GutTest


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


func test_classic_constructive_unique_and_solvable() -> void:
	var gen := PuzzleGenerator.new()
	var level := gen.generate_constructive("classic", Vector2i(5, 5), 6, 42)
	assert_false(level.is_empty(), "classic 构造式应生成非空关卡")
	if level.is_empty():
		return
	assert_eq(level["mines"].size(), level["total_mines"], "雷数应一致")

	# 加载（settle：翻开 givens 触发连锁扩散）
	var board := Board.new()
	board.load_level(level)

	# 唯一解：settle 后约束集解数 == 1
	var oracle := BruteForceOracle.new()
	var revealed := _collect_revealed(board)
	var cnt := oracle.count_solutions_variant(board.grid.size(), revealed, board.total_mines, ClassicConstraint.check, [], 2)
	assert_eq(cnt, 1, "构造式关卡应唯一解（解数=%d）" % cnt)

	# 纯逻辑可解（solve 会改 board，故重新加载）
	var board2 := Board.new()
	board2.load_level(level)
	var player := SolverPerfectPlayer.new()
	var result := player.solve(board2, ClassicConstraint.check)
	assert_true(result[0], "构造式关卡应纯逻辑可解（步数=%d）" % result[1])


func test_variant_constructive_smoke() -> void:
	# 变体构造式：验证能生成非空（不卡死）+ 雷数一致。唯一解/可解由 classic 已覆盖。
	var gen := PuzzleGenerator.new()
	var cases := {
		"mx": [5, 5, 6],
		"qd": [5, 5, 6],
		"ep": [5, 5, 6],
		"rl": [5, 5, 6],
		"4n": [5, 5, 6],
		"sc": [5, 5, 6],
	}
	for code in cases:
		var spec: Array = cases[code]
		var level := gen.generate_constructive(code, Vector2i(spec[0], spec[1]), spec[2], 7)
		assert_false(level.is_empty(), "%s 构造式应生成非空关卡" % code)
		if level.is_empty():
			continue
		assert_eq(level["mines"].size(), level["total_mines"], "%s 雷数应一致" % code)


func test_classic_constructive_many_seeds() -> void:
	# 多 seed 稳定性：classic 构造式成功率应 >50%
	var gen := PuzzleGenerator.new()
	var ok := 0
	var total := 20
	for s in total:
		var level := gen.generate_constructive("classic", Vector2i(5, 5), 6, s)
		if not level.is_empty():
			ok += 1
	gut.p("  classic 构造式成功率: %d/%d" % [ok, total])
	assert_gt(ok, total / 2, "classic 构造式成功率应 >50%%（%d/%d）" % [ok, total])
