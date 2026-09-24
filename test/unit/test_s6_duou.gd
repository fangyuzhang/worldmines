# test_s6_duou.gd —— S6「度偶数」单元测试（GUT）
# 覆盖：插件契约、度数全偶（独立复算）、雷数守恒、成功率下界、
# 构造基元性质（3×3 环的角格度 2 / 边格度 4 均为偶数；孤点度 0）。
extends GutTest

const MOD_DIR := "res://demo/mods/s6_duou"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const TRIALS := 20
const DIRS8 := [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	autofree(api)
	api.load_mod(MOD_DIR)


func _even_ok(ms: Dictionary) -> bool:
	for p in ms:
		var deg := 0
		for d in DIRS8:
			if ms.has((p as Vector2i) + d):
				deg += 1
		if deg % 2 != 0:
			return false
	return true


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s6")
	assert_not_null(r, "s6 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "S6 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "度偶数", "名称应为「度偶数」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


## 构造基元：3×3 环（8 格，中心空）——角格度 2、边格度 4，全为偶数。
func test_ring_primitive_degrees() -> void:
	var ring: Array[Vector2i] = []
	for d in [[0, 0], [1, 0], [2, 0], [0, 1], [2, 1], [0, 2], [1, 2], [2, 2]]:
		ring.append(Vector2i(int(d[0]), int(d[1])))
	assert_eq(ring.size(), 8, "3×3 环应为 8 格")
	var ms := {}
	for p in ring:
		ms[p] = true
	assert_true(_even_ok(ms), "3×3 环应满足「所有雷的度数为偶数」")
	# 角格 (0,0)：邻雷 (1,0) (0,1) → 度 2（(1,1) 为中心，空）
	var deg_corner := 0
	for d in DIRS8:
		if ms.has(Vector2i(0, 0) + d):
			deg_corner += 1
	assert_eq(deg_corner, 2, "环角格度数应为 2")
	# 边格 (1,0)：邻雷 (0,0) (2,0) (0,1) (2,1) → 度 4
	var deg_edge := 0
	for d in DIRS8:
		if ms.has(Vector2i(1, 0) + d):
			deg_edge += 1
	assert_eq(deg_edge, 4, "环边格度数应为 4")


## 全尺寸布雷：雷数守恒 + 度数全偶 + 成功率下界。
func test_place_mines_all_sizes() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s6")
	assert_not_null(r, "s6 未注册")
	for side in [5, 6, 7, 8, 9]:
		var want: int = R07_MINES[side]
		var ok_cnt := 0
		for t in TRIALS:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 3571 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			for m in mines:
				ms[m] = true
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复" % [side, side])
			assert_true(_even_ok(ms), "%dx%d 每颗雷的八邻域雷数应为偶数" % [side, side])
		assert_gt(float(ok_cnt) / float(TRIALS), 0.5,
			"%dx%d 构造式布雷成功率应 > 50%%（实测 %d/%d）" % [side, side, ok_cnt, TRIALS])
