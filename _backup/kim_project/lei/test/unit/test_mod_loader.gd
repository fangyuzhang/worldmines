# test_mod_loader.gd —— mod 规则包加载测试（文档第二篇 §2.5 / §7）
extends GutTest


func test_load_clue_def_and_solve() -> void:
	var loader := ModLoader.new()
	var json := '{"defName": "My4N", "type": "clue", "window": "n4", "aggregate": "sum", "value_range": [0, 4], "empty_value": 0}'
	var r: Dictionary = loader.load_clue_def(json)
	assert_true(r["ok"], "加载线索 Def 应成功：%s" % r.get("reason", ""))

	# 构造 3×3 N4 棋盘：中心 value=1，上邻是雷（标旗）
	var board := Board.new()
	var grid := RectGrid.new()
	grid.setup(3, 3)
	board.grid = grid
	board.total_mines = 1
	board.clue_variant = ClueEngine.Variant.N4
	board._static_mines = [Vector2i(1, 0)]
	grid.get_cell(Vector2i(1, 0)).is_mine = true
	board._compute_clues()
	grid.get_cell(Vector2i(1, 1)).state = Cell.State.REVEALED
	grid.get_cell(Vector2i(1, 0)).state = Cell.State.FLAGGED

	# 共享 engine，用 mod 规则求解
	var solver := HintSolver.new()
	solver.engine = loader.engine
	var steps := solver.hint_def(board, "My4N")
	var safe_count := 0
	for s in steps:
		if s.state == "safe" and s.sources.has(Vector2i(1, 1)):
			safe_count += 1
	assert_eq(safe_count, 3, "mod 规则（n4+sum）应推出 3 个安全格")


func test_load_constraint_def() -> void:
	var loader := ModLoader.new()
	var json := '{"defName": "MyMirror", "type": "constraint", "op": "symmetry_axis", "axis": "vertical"}'
	var r: Dictionary = loader.load_constraint_def(json)
	assert_true(r["ok"], "加载约束 Def 应成功：%s" % r.get("reason", ""))
	var mine_set := {Vector2i(0, 0): true, Vector2i(2, 0): true}
	assert_true(loader.engine.check_constraint("MyMirror", mine_set, Vector2i(3, 3)), "镜像约束应满足")


func test_load_sum_equality_region() -> void:
	var loader := ModLoader.new()
	var json := '{"defName": "MyQuadrant", "type": "constraint", "op": "sum_equality", "region": "quadrant"}'
	var r: Dictionary = loader.load_constraint_def(json)
	assert_true(r["ok"], "加载 sum_equality+quadrant 约束应成功：%s" % r.get("reason", ""))


func test_reject_bad_json() -> void:
	var loader := ModLoader.new()
	var r1: Dictionary = loader.load_clue_def('{"type": "clue", "window": "n999", "aggregate": "sum"}')
	assert_false(r1["ok"], "不支持的 window 应被拒绝")
	var r2: Dictionary = loader.load_constraint_def('{"type": "constraint", "op": "unknown_op"}')
	assert_false(r2["ok"], "不支持的 op 应被拒绝")


func test_load_mod_dir() -> void:
	var mod_dir := "user://test_mod"
	DirAccess.make_dir_recursive_absolute(mod_dir.path_join("defs"))
	var f1 := FileAccess.open(mod_dir.path_join("defs/clue1.json"), FileAccess.WRITE)
	f1.store_string('{"defName": "Dir4N", "type": "clue", "window": "n4", "aggregate": "sum", "value_range": [0, 4]}')
	f1.close()
	var f2 := FileAccess.open(mod_dir.path_join("defs/constraint1.json"), FileAccess.WRITE)
	f2.store_string('{"defName": "DirMirror", "type": "constraint", "op": "symmetry_axis"}')
	f2.close()

	var loader := ModLoader.new()
	var r: Dictionary = loader.load_mod_dir(mod_dir)
	assert_true(r["ok"], "加载 mod 目录应成功：%s" % r.get("reason", ""))
	assert_eq(r["loaded"], 2, "应加载 2 个 Def")
	var mine_set := {Vector2i(1, 0): true}
	assert_eq(loader.engine.compute_clue("Dir4N", mine_set, Vector2i(1, 1), Vector2i(3, 3)), 1, "目录加载的线索 Def 应可用")
