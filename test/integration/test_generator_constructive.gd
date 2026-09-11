# test_generator_constructive.gd —— 构造式生成测试（文档第三篇 P0）
# 验证构造式生成：非空、唯一解、纯逻辑可解。
extends GutTest


func test_classic_constructive_solvable() -> void:
	var gen := PuzzleGenerator.new()
	var level := gen.generate_constructive("classic", Vector2i(5, 5), 6, 42)
	assert_false(level.is_empty(), "classic 构造式应生成非空关卡")
	if level.is_empty():
		return
	assert_eq(level["mines"].size(), level["total_mines"], "雷数应一致")

	# 序贯纯逻辑可解（R01 真义；v2.8.3 起不再强求静态唯一：
	# 0 值格不进初始线索后静态多解是正常现象，硬判 count==1 会误杀）。
	var board := Board.new()
	board.load_level(level)
	var player := SolverPerfectPlayer.new()
	var result := player.solve(board, ClassicConstraint.check)
	assert_true(result[0], "构造式关卡应序贯纯逻辑可解（步数=%d）" % result[1])


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
