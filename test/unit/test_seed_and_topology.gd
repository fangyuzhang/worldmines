# test_seed_and_topology.gd —— 方案 A/B/C/D 的单元测试
# 覆盖：种子配方往返 / 层级种子确定性 / 异形拓扑加载与线索 / 分块覆盖 / 离线生成+回放。
extends GutTest


func test_seed_recipe_roundtrip() -> void:
	var r := SeedRecipe.new()
	r.seed = 42
	r.topology_kind = "adjacency"
	r.clue_rule_id = "classic"
	r.global_rule_ids = ["mx"]
	var d := r.to_dict()
	var r2 := SeedRecipe.from_dict(d)
	assert_eq(r2.seed, 42, "seed 往返")
	assert_eq(r2.topology_kind, "adjacency", "topology_kind 往返")
	assert_eq(r2.clue_rule_id, "classic", "clue_rule_id 往返")
	assert_eq(r2.global_rule_ids, ["mx"], "global_rule_ids 往返")


func test_deterministic_random_stable() -> void:
	var a := DeterministicRandom.derive(7, "mines", 0)
	var b := DeterministicRandom.derive(7, "mines", 0)
	assert_eq(a, b, "同 seed 同阶段应得同子种子")
	var c := DeterministicRandom.derive(7, "prune", 0)
	assert_ne(a, c, "不同阶段应得不同子种子")


func test_adjacency_board_load_and_clue() -> void:
	# 一条 5 格链 0-1-2-3-4（邻接表），(2) 为雷
	var level := {
		"topology": {
			"positions": [
				{"x": 0, "y": 0}, {"x": 1, "y": 0}, {"x": 2, "y": 0}, {"x": 3, "y": 0}, {"x": 4, "y": 0}
			],
			"adjacency": [
				{"a": {"x": 0, "y": 0}, "b": {"x": 1, "y": 0}},
				{"a": {"x": 1, "y": 0}, "b": {"x": 2, "y": 0}},
				{"a": {"x": 2, "y": 0}, "b": {"x": 3, "y": 0}},
				{"a": {"x": 3, "y": 0}, "b": {"x": 4, "y": 0}},
			]
		},
		"total_mines": 1,
		"mines": [{"c": 2, "r": 0}],
		"revealed": [],
	}
	var board := Board.new()
	board.load_level(level)
	# 格子 1 邻接 (0,2)，其中 (2) 是雷 → 线索值 1
	assert_eq(board.grid.get_cell(Vector2i(1, 0)).value, 1, "邻域计数线索应为 1")
	# 格子 0 邻接 (1)，非雷 → 0
	assert_eq(board.grid.get_cell(Vector2i(0, 0)).value, 0, "链端点线索应为 0")
	# 格子 3 邻接 (2,4)，(2) 是雷 → 1
	assert_eq(board.grid.get_cell(Vector2i(3, 0)).value, 1, "格子3线索应为 1")


func test_chunker_covers_all_cells() -> void:
	var rg := RectGrid.new()
	rg.setup(6, 6)
	var rng := DeterministicRandom.make_rng(3, DeterministicRandom.STAGE_CHUNK)
	var plan := Chunker.plan(rg, 12, rng)
	var covered := {}
	for b in plan.blocks:
		for p in b.cell_ids:
			covered[p] = true
	assert_eq(covered.size(), 36, "分块应覆盖全部 36 格")
	assert_gt(plan.blocks.size(), 1, "6x6 以 12 格分块应产生多块")


func test_level_generator_adjacency_roundtrip() -> void:
	var r := SeedRecipe.new()
	r.seed = 5
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
	var gen := LevelGenerator.new()
	var level := gen.generate(r)
	assert_false(level.is_empty(), "异形关卡应生成")
	assert_eq(level["total_mines"], 2, "雷数应一致")
	assert_true(level.has("topology"), "关卡应带 topology 字段")
	# 加载验证
	var board := Board.new()
	board.load_level(level)
	assert_eq(board.total_mines, 2, "Board 加载异形关卡雷数一致")


func test_offline_generate_and_replay() -> void:
	var r := SeedRecipe.new()
	r.seed = 11
	r.topology_kind = "rect"
	r.topology_params = {"rows": 5, "cols": 5}
	r.clue_rule_id = "classic"
	r.mine_count = 6
	var og := OfflineGenerator.new()
	var arts := og.batch([r])
	assert_eq(arts.size(), 1, "批量生成 1 个产物")
	var verifier := ReplayVerifier.new()
	assert_true(verifier.verify(arts[0]), "回放校验应通过（同种子同盘）")
