extends GutTest
## Def→规则平台桥的回归测试（2026-10-25）。
## 现状口径（以代码为准）：`generate_with_engine` 已把 Def 的 (window,aggregate)/op
## 翻译成规则 id 并统一委托 `generate_with_rules`——两条链已合一，本文件钉住这个契约。
## 旧交接文档「Def 桥尚未做」的说法已过期，随本测试一并修正。

const SIZE_5 := Vector2i(5, 5)
const MINES_5 := 10  # R07 口径：5×5 = 10 雷


func test_clue_def_equivalence_table() -> void:
	var engine := DefEngine.new()
	# 抽 4 个已知等价对（映射表见 core/puzzle_generator.gd _def_clue_to_rule）
	assert_eq(PuzzleGenerator.def_to_rule(engine, "classic", true), "classic", "n8+sum ≡ classic")
	assert_eq(PuzzleGenerator.def_to_rule(engine, "4n", true), "4n", "n4 ≡ 4n")
	assert_eq(PuzzleGenerator.def_to_rule(engine, "loopruns", true), "loopruns", "ring8+run_count ≡ loopruns")
	assert_eq(PuzzleGenerator.def_to_rule(engine, "clock", true), "clock", "ring8+first_index ≡ clock")


func test_unknown_def_returns_empty() -> void:
	var engine := DefEngine.new()
	assert_eq(PuzzleGenerator.def_to_rule(engine, "no_such_def", true), "", "未知 Def 名应无等价规则")
	assert_true(PuzzleGenerator.new().generate_from_def("no_such_def", "", SIZE_5, MINES_5, 11).is_empty(),
		"未知线索 Def 生成必须失败（空字典），不得静默换规则")
	assert_true(PuzzleGenerator.new().generate_from_def("classic", "no_such_constraint", SIZE_5, MINES_5, 11).is_empty(),
		"未知约束 Def 生成必须失败（空字典）")


func test_generate_from_def_uses_rule_platform() -> void:
	var pg := PuzzleGenerator.new()
	var lv: Dictionary = pg.generate_from_def("4n", "", SIZE_5, MINES_5, 7)
	assert_false(lv.is_empty(), "4n Def 生成 5x5 应成功")
	if lv.is_empty():
		return
	assert_eq(str(lv.get("clue_rule", "")), "4n", "生成的关卡 clue_rule 应等于等价规则 id（桥的核心契约）")
	# 与入库关卡同契约（import_batch_to_lib 的 REQUIRED_FIELDS 口径）
	for field in ["mines", "revealed", "size", "total_mines"]:
		assert_true(lv.has(field), "生成关卡必须含必需字段 %s" % field)


func test_bridge_contract_matches_rules_chain() -> void:
	# 同 seed 下「Def 链」与「规则链」产物一致——两条链合一的直接证据。
	var pg2 := PuzzleGenerator.new()
	var from_def: Dictionary = pg2.generate_from_def("classic", "", SIZE_5, MINES_5, 23)
	var from_rules: Dictionary = pg2.generate_with_rules("classic", [], SIZE_5, MINES_5, 23)
	assert_false(from_def.is_empty(), "Def 链应产出")
	assert_false(from_rules.is_empty(), "规则链应产出")
	if from_def.is_empty() or from_rules.is_empty():
		return
	assert_eq(from_def.get("mines", []), from_rules.get("mines", []), "同 seed 两条链布雷必须逐位一致")
	assert_eq(int(from_def.get("total_mines", -1)), int(from_rules.get("total_mines", -1)), "总雷数一致")
