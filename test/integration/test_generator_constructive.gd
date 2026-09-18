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
	# 注意本入口按**旧变体码表**（VariantRegistry.resolve）解析 —— 官方 22 席不在该表里，
	# 走下面那条 generate_with_rules 的用例（两条入口的分工见 HANDOFF）。
	var gen := PuzzleGenerator.new()
	var cases := {
		"mx": [5, 5, 6],
		"qd": [5, 5, 6],
		"rl": [5, 5, 6],
	}
	for code in cases:
		var spec: Array = cases[code]
		var level := gen.generate_constructive(code, Vector2i(spec[0], spec[1]), spec[2], 7)
		assert_false(level.is_empty(), "%s 构造式应生成非空关卡" % code)
		if level.is_empty():
			continue
		assert_eq(level["mines"].size(), level["total_mines"], "%s 雷数应一致" % code)


## 官方三轴席位的构造式生成：必须走**规则平台入口**——`generate_constructive` 只认旧变体码表
## （VariantRegistry），对官方 22 席会直接返回空（不是算子坏，是入口不同）。
## 这里覆盖结构（s1 局部禁形）与观测（o1 对穿 / o2 邻序 / o7 奇显）在 7×7 的出关。
func test_official_axes_constructive_smoke() -> void:
	var gen := PuzzleGenerator.new()
	var cases := {
		"o1": [7, 7, 12],
		"o2": [7, 7, 12],
		"o7": [7, 7, 12],
	}
	for code in cases:
		var spec: Array = cases[code]
		var level := gen.generate_with_rules(code, [], Vector2i(spec[0], spec[1]), spec[2], 7)
		assert_false(level.is_empty(), "%s 应能构造式生成非空关卡" % code)
		if level.is_empty():
			continue
		assert_eq(level["mines"].size(), level["total_mines"], "%s 雷数应一致" % code)

	# 结构轴算子走**约束位置**：s1 是 KIND_GLOBAL（约束），不是线索。
	# 曾经把它当 clue 传（`generate_with_rules("s1", [], …)`）→ 生成器找不到这个线索规则、
	# 一路返回空，看上去像「该算子产不出关卡」，白查了一轮（temp probe 实测：它的布雷器
	# 完全正常，7×7/12 → 12 颗、8×8/26 → 26 颗，纯属参数放错位置）。
	var s1_level := gen.generate_with_rules("classic", ["s1"], Vector2i(7, 7), 12, 7)
	assert_false(s1_level.is_empty(), "classic+s1（结构轴约束）应能构造式生成非空关卡")
	if not s1_level.is_empty():
		assert_eq(s1_level["mines"].size(), s1_level["total_mines"], "classic+s1 雷数应一致")


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
