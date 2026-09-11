# test_generator_crosscheck.gd —— 生成器交叉验证：CP-SAT 序贯演绎 vs 独立 BruteForceOracle 完美玩家
# 核心：生成器用 CP-SAT forced-cell 验证「序贯纯逻辑可解」，
# 这里用完全独立的 BruteForceOracle（完备穷举）+ SolverPerfectPlayer 对拍。
# 若两者结论不一致 → CP-SAT forced-cell 检测有 bug（漏判/误判强制格）。
extends GutTest


## 用独立 BruteForceOracle 完美玩家验证生成器产出的「可解」声明。
func _independent_solvable(clue_id: String, global_ids: Array, level: Dictionary) -> bool:
	var board := Board.new()
	board.load_level(level)
	var reg := RuleRegistry.default()
	var clue: Object = reg.resolve(StringName(clue_id))
	var globals: Array = []
	for gid in global_ids:
		globals.append(reg.resolve(StringName(gid)))
	var size := Vector2i(int(level["size"]["cols"]), int(level["size"]["rows"]))
	var total_mines := int(level["total_mines"])
	var oracle := RuleOracle.new(clue, globals, size, total_mines)
	var player := SolverPerfectPlayer.new()
	# timeout 保护：完备穷举在小盘可接受，加墙钟兜底
	var result := player.solve(board, oracle.check_callable(), 20_000)
	return bool(result[0])


func test_classic_and_globals_independent_solvable() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var gen := PuzzleGenerator.new()
	var combos := [
		["classic", []],
		["classic", ["mx"]],
		["classic", ["rl"]],
		["classic", ["pf"]],
		["classic", ["ep"]],
		["classic", ["dt"]],
	]
	for combo in combos:
		for seed in range(1, 4):
			var level := gen.generate_with_rules(combo[0], combo[1], Vector2i(5, 5), 5, seed)
			if level.is_empty():
				continue
			assert_true(_independent_solvable(combo[0], combo[1], level),
				"%s+%s seed%d 独立 Oracle 应可解" % [combo[0], str(combo[1]), seed])


func test_clue_variants_independent_solvable() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var gen := PuzzleGenerator.new()
	for clue_id in ["4n", "sc", "distsum"]:
		var level := gen.generate_with_rules(clue_id, [], Vector2i(5, 5), 5, 1)
		if level.is_empty():
			continue
		assert_true(_independent_solvable(clue_id, [], level),
			"%s 独立 Oracle 应可解" % clue_id)


## 遮蔽关卡：遮蔽格 interval 语义在加载 + 独立验证下仍可解。
func test_masked_independent_solvable() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var gen := PuzzleGenerator.new()
	for seed in range(1, 5):
		var level := gen.generate_with_rules("classic", [], Vector2i(5, 5), 6, seed, 2)
		if level.is_empty():
			continue
		# 确认有遮蔽格
		var has_masked := false
		for rc in level["revealed"]:
			if rc.has("interval"):
				has_masked = true
		if not has_masked:
			continue
		assert_true(_independent_solvable("classic", [], level),
			"遮蔽关卡 seed%d 独立 Oracle 应可解" % seed)


## 剩余全局约束（qd 四象 / 4c 四色）独立可解。
func test_remaining_globals_independent_solvable() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var gen := PuzzleGenerator.new()
	# qd 需偶数雷；4c 需偶数雷（黑白各半）
	for combo in [["qd", 4], ["4c", 4]]:
		var level := gen.generate_with_rules("classic", [combo[0]], Vector2i(5, 5), combo[1], 1)
		if level.is_empty():
			continue
		assert_true(_independent_solvable("classic", [combo[0]], level),
			"classic+%s 独立 Oracle 应可解" % combo[0])


## 遮蔽 + 全局约束组合：interval 语义在全局约束下仍独立可解。
func test_masked_with_global_independent_solvable() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var gen := PuzzleGenerator.new()
	for seed in range(1, 5):
		var level := gen.generate_with_rules("classic", ["mx"], Vector2i(5, 5), 4, seed, 1)
		if level.is_empty():
			continue
		var has_masked := false
		for rc in level["revealed"]:
			if rc.has("interval"):
				has_masked = true
		if not has_masked:
			continue
		assert_true(_independent_solvable("classic", ["mx"], level),
			"遮蔽+镜像 seed%d 独立 Oracle 应可解" % seed)


## 异形拓扑（洞格）独立可解：生成 → 加载 → 洞格非雷 + 线索一致 + 可解。
func test_topology_independent_solvable() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var r := SeedRecipe.new()
	r.seed = 7
	r.topology_kind = "adjacency"
	r.clue_rule_id = "classic"
	r.mine_count = 2
	r.topology_params = {
		"positions": [
			{"x": 0, "y": 0}, {"x": 1, "y": 0}, {"x": 2, "y": 0},
			{"x": 0, "y": 1}, {"x": 1, "y": 1}, {"x": 2, "y": 1},
		],
		"adjacency": [
			{"a": {"x": 0, "y": 0}, "b": {"x": 1, "y": 0}},
			{"a": {"x": 1, "y": 0}, "b": {"x": 2, "y": 0}},
			{"a": {"x": 0, "y": 0}, "b": {"x": 0, "y": 1}},
			{"a": {"x": 1, "y": 0}, "b": {"x": 1, "y": 1}},
			{"a": {"x": 2, "y": 0}, "b": {"x": 2, "y": 1}},
			{"a": {"x": 0, "y": 1}, "b": {"x": 1, "y": 1}},
			{"a": {"x": 1, "y": 1}, "b": {"x": 2, "y": 1}},
		]
	}
	var level := LevelGenerator.new().generate(r)
	if level.is_empty():
		pending("异形生成失败（跳过）")
		return
	var board := Board.new()
	board.load_level(level)
	assert_eq(board.total_mines, 2, "异形关卡雷数一致")
	# 独立 Oracle 可解（6 格 2 雷，C(4,2) 小，可穷举）
	var reg := RuleRegistry.default()
	var clue: Object = reg.resolve(&"classic")
	var topo: GridInterface = board.grid
	var oracle := RuleOracle.new(clue, [], Vector2i(3, 2), 2, topo)
	var player := SolverPerfectPlayer.new()
	var result := player.solve(board, oracle.check_callable(), 20_000)
	assert_true(result[0], "异形拓扑关卡独立 Oracle 应可解")


## DT 骨牌往返：dominoes 落盘 → 加载 → 每骨牌恰 1 雷 + 可解。
## 注：独立 Oracle 用完备穷举，组合数受 MAX_COMBOS 保护——DT 用 4×4 小盘（C(16,4)=1820）确保可穷举。
func test_dt_dominoes_roundtrip() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var gen := PuzzleGenerator.new()
	var level := gen.generate_with_rules("classic", ["dt"], Vector2i(4, 4), 4, 1)
	if level.is_empty():
		pending("DT 生成失败（跳过）")
		return
	assert_true(level.has("dominoes"), "DT 关卡应落盘 dominoes")
	var board := Board.new()
	board.load_level(level)
	assert_eq(board.dominoes.size(), int(level["total_mines"]), "骨牌数应等于雷数")
	# 每骨牌恰 1 雷
	var mine_set := {}
	for m in level["mines"]:
		mine_set[Vector2i(int(m["c"]), int(m["r"]))] = true
	for d in board.dominoes:
		var cnt := 0
		for p in d:
			if mine_set.has(p):
				cnt += 1
		assert_eq(cnt, 1, "每骨牌应恰 1 雷")
	# 独立可解
	assert_true(_independent_solvable("classic", ["dt"], level), "DT 关卡独立 Oracle 应可解")
