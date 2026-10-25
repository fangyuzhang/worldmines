# test_mod_generation.gd —— mod 关卡生成 + 加载 + 线索一致性（第二篇 mod 系统集成）
extends GutTest


## 用 mod Def（内置 DefEngine 的 4n + mx）生成关卡 → DefEngine 加载 → 线索值一致。
func test_mod_level_generate_and_load() -> void:
	var gen := PuzzleGenerator.new()
	var level := gen.generate_from_def("4n", "mx", Vector2i(5, 5), 5, 1)
	assert_false(level.is_empty(), "mod 关卡应生成")
	assert_eq(str(level.get("clue_def", "")), "4n", "clue_def 字段应为 4n")
	assert_eq(str(level.get("constraint_def", "")), "mx", "constraint_def 字段应为 mx")

	var engine := DefEngine.new()
	var board := Board.new()
	board.def_engine = engine
	board.load_level(level)
	assert_eq(board.clue_def_name, "4n", "加载后 clue_def_name")
	assert_eq(board.constraint_def_name, "mx", "加载后 constraint_def_name")

	var ok := true
	for rv in level.get("revealed", []):
		var pos := Vector2i(int(rv["c"]), int(rv["r"]))
		var expected: Variant = engine.compute_clue("4n", board._mine_set_dict(), pos, Vector2i(5, 5))
		if str(expected) != str(board.grid.get_cell(pos).value):
			ok = false
	assert_true(ok, "mod 关卡线索值应与 DefEngine 计算一致")


## 无约束 mod 关卡（仅线索 Def）也能生成 + 加载。
func test_mod_level_clue_only() -> void:
	var gen := PuzzleGenerator.new()
	var level := gen.generate_from_def("sc", "", Vector2i(5, 5), 5, 1)
	assert_false(level.is_empty(), "仅线索 Def 的 mod 关卡应生成")
	var board := Board.new()
	board.def_engine = DefEngine.new()
	board.load_level(level)
	assert_eq(board.clue_def_name, "sc", "加载后 clue_def_name")
	assert_eq(board.constraint_def_name, "", "无约束时 constraint_def_name 应为空")
