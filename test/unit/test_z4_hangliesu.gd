# test_z4_hangliesu.gd —— Z4「行列同序」单元测试（GUT）
# 覆盖：插件契约、行和≡列和（独立复算）、雷数守恒、成功率下界、
# 边界（非方阵不施加约束 → 构造式布雷返回空，不误产）。
extends GutTest

const MOD_DIR := "res://demo/mods/z4_hangliesu"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const TRIALS := 30


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod(MOD_DIR)


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z4")
	assert_not_null(r, "z4 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "Z4 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "行列同序", "名称应为「行列同序」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


## 全尺寸布雷：雷数守恒 + 行和 ≡ 列和 + 成功率下界。
func test_place_mines_all_sizes() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z4")
	assert_not_null(r, "z4 未注册")
	for side in [5, 6, 7, 8, 9]:
		var want: int = R07_MINES[side]
		var ok_cnt := 0
		for t in TRIALS:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 5471 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			for m in mines:
				ms[m] = true
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复" % [side, side])
			var row_cnt: Array = []
			var col_cnt: Array = []
			for i in side:
				row_cnt.append(0)
				col_cnt.append(0)
			for m in mines:
				row_cnt[(m as Vector2i).y] = int(row_cnt[(m as Vector2i).y]) + 1
				col_cnt[(m as Vector2i).x] = int(col_cnt[(m as Vector2i).x]) + 1
			assert_eq(row_cnt, col_cnt,
				"%dx%d 行和序列应等于列和序列（行=%s 列=%s）" % [side, side, str(row_cnt), str(col_cnt)])
		assert_gt(float(ok_cnt) / float(TRIALS), 0.9,
			"%dx%d 构造式布雷成功率应 > 90%%（实测 %d/%d）" % [side, side, ok_cnt, TRIALS])


## 边界：非方阵——规则不适用（不施加约束），构造式布雷直接返回空（不误产）。
func test_non_square_rejected() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z4")
	assert_not_null(r, "z4 未注册")
	var rng := RandomNumberGenerator.new()
	rng.seed = 999
	var mines: Array = r.call("place_mines", rng, 6, 5, 14)
	assert_eq(mines.size(), 0, "非方阵（6×5）应返回空（规则仅适用方阵）")
