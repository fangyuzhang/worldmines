# test_z1_jingxiang.gd —— Z1「镜像」单元测试（GUT）
# 覆盖：插件契约、左右逐格对称（独立复算）、雷数守恒、成功率下界。
extends GutTest

const MOD_DIR := "res://demo/mods/z1_jingxiang"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const TRIALS := 25


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod(MOD_DIR)


func _mirror_ok(ms: Dictionary, n: int) -> bool:
	for r in n:
		for c in int(n / 2):
			if ms.has(Vector2i(c, r)) != ms.has(Vector2i(n - 1 - c, r)):
				return false
	return true


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z1")
	assert_not_null(r, "z1 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "Z1 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "镜像", "名称应为「镜像」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


func test_place_mines_all_sizes() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z1")
	assert_not_null(r, "z1 未注册")
	for side in [5, 6, 7, 8, 9]:
		var want: int = R07_MINES[side]
		var ok_cnt := 0
		for t in TRIALS:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 2237 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			for m in mines:
				ms[m] = true
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复" % [side, side])
			assert_true(_mirror_ok(ms, side), "%dx%d 应左右逐格对称" % [side, side])
		assert_gt(float(ok_cnt) / float(TRIALS), 0.9,
			"%dx%d 构造式布雷成功率应 > 90%%（实测 %d/%d）" % [side, side, ok_cnt, TRIALS])
