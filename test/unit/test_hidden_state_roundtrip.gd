# test_hidden_state_roundtrip.gd —— 隐藏态「落盘 / 恢复」回归测试（GUT）
# 背景：HANDOFF 已知坑 #18——隐藏态规则（o4/o5x）载盘后状态丢失 → 线索数字全错。
# 覆盖：① 生成盘必含 hidden_state 字段；② export/import round-trip；
#      ③ 修复路径：清空状态 + 带字段载盘 → 推理可解；④ o5x 旧盘对照（无字段不可解）；
#      ⑤ 基类默认契约（无隐藏态规则零影响）。
extends GutTest

const O5X_DIR := "res://demo/mods/o5_xiemai"
const O4_DIR := "res://demo/mods/o4_bianjing"


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod(O5X_DIR)
	api.load_mod(O4_DIR)


func _gen(clue_id: String) -> Dictionary:
	var gen := PuzzleGenerator.new()
	return gen.generate_with_rules(clue_id, [], Vector2i(6, 6), 14, 7, 0, 20, null, 30000)


func test_o5x_level_has_hidden_state() -> void:
	var level: Dictionary = _gen("o5x")
	assert_false(level.is_empty(), "生成成功（o5x 6x6）")
	var hs: Dictionary = level.get("hidden_state", {})
	assert_true(hs.has("o5x"), "落盘含 hidden_state[o5x]")
	var arr: Array = (hs.get("o5x", {}) as Dictionary).get("s1", [])
	assert_eq(arr.size(), 9, "6x6 的 s1 数量 = k = 36/4 = 9")


func test_o5x_roundtrip_and_recovery() -> void:
	var level: Dictionary = _gen("o5x")
	assert_false(level.is_empty(), "生成成功")
	var rule: Object = RuleRegistry.default().resolve(&"o5x")
	# round-trip：导出 → 清空 → 恢复 → 再导出一致
	var e1: Dictionary = rule.call("export_hidden_state")
	rule.call("import_hidden_state", {})
	assert_true((rule.call("export_hidden_state") as Dictionary).get("s1", []).is_empty(), "清空生效")
	rule.call("import_hidden_state", e1)
	assert_eq(rule.call("export_hidden_state"), e1, "import(export()) == 原状态")
	# 旧盘对照：无字段 + 状态被清空 → 应不可解（复现修复前行为）
	var old_level: Dictionary = level.duplicate(true)
	old_level.erase("hidden_state")
	rule.call("import_hidden_state", {})
	assert_false(bool(ProofLog.build(old_level).get("solved", false)), "旧盘（无字段）不可解——修复前病态复现")
	# 修复路径：带字段载盘 → 自动恢复 → 应可解
	assert_true(bool(ProofLog.build(level).get("solved", false)), "带字段载盘后可解——修复生效")


func test_o4_level_has_hidden_state() -> void:
	var level: Dictionary = _gen("o4")
	assert_false(level.is_empty(), "生成成功（o4 6x6）")
	var hs: Dictionary = level.get("hidden_state", {})
	assert_true(hs.has("o4"), "落盘含 hidden_state[o4]")
	var arr: Array = (hs.get("o4", {}) as Dictionary).get("r2", [])
	assert_eq(arr.size(), 9, "6x6 的 r2 数量 = k = 36/4 = 9")


func test_o4_recovery() -> void:
	var level: Dictionary = _gen("o4")
	assert_false(level.is_empty(), "生成成功")
	var rule: Object = RuleRegistry.default().resolve(&"o4")
	# 清空状态 + 带字段载盘 → 自动恢复 → 应可解
	rule.call("import_hidden_state", {})
	assert_true(bool(ProofLog.build(level).get("solved", false)), "带字段载盘后可解（o4）")


func test_base_plugin_default_contract() -> void:
	# 无隐藏态规则走基类默认：导出空字典、导入为空操作（零影响契约）
	var base := RulePlugin.new()
	assert_true((base.export_hidden_state() as Dictionary).is_empty(), "基类默认导出空字典")
	base.import_hidden_state({})
	assert_true(true, "基类默认导入不报错")
