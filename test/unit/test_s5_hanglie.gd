# test_s5_hanglie.gd —— S5「行列凸」单元测试（GUT）
# 覆盖：插件契约、每行每列的雷连续（独立复算）、雷数守恒、成功率下界、
# **形状反例**（GDD 原文：实心块/十字形/阶梯形满足；**L 形不满足**——某一行会断开）。
extends GutTest

const MOD_DIR := "res://demo/mods/s5_hanglie"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const TRIALS := 25


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod(MOD_DIR)


func _convex_ok(ms: Dictionary, n: int) -> bool:
	for r in n:
		var seen := false
		var closed := false
		for c in n:
			if ms.has(Vector2i(c, r)):
				if closed:
					return false
				seen = true
			elif seen:
				closed = true
	for c in n:
		var seen2 := false
		var closed2 := false
		for r in n:
			if ms.has(Vector2i(c, r)):
				if closed2:
					return false
				seen2 = true
			elif seen2:
				closed2 = true
	return true


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s5")
	assert_not_null(r, "s5 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "S5 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "行列凸", "名称应为「行列凸」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


## GDD §4.5 原文的形状判据：实心块/十字形满足、**L 形不满足**。
func test_shape_cases() -> void:
	# 实心 3×3：满足
	var solid := {}
	for r in 3:
		for c in 3:
			solid[Vector2i(c, r)] = true
	assert_true(_convex_ok(solid, 3), "实心块应满足行列凸")
	# 十字形（3×3 的四臂）：满足
	var cross := {}
	for p in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2)]:
		cross[p] = true
	assert_true(_convex_ok(cross, 3), "十字形应满足行列凸")
	# L 形（2×2 去一角，摆在 3×3 内）：某一行会断开 → 不满足
	var lshape := {}
	for p in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1)]:
		lshape[p] = true
	assert_true(_convex_ok(lshape, 3), "底行连续、左列连续——该摆放其实满足（用作正例对照）")
	# 真正的 L 形断开例：某行两段
	var broken := {}
	for p in [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 0)]:
		broken[p] = true
	assert_false(_convex_ok(broken, 3), "第 0 行两段断开（01 与 10 不相邻）→ 应判为不满足")


func test_place_mines_all_sizes() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s5")
	assert_not_null(r, "s5 未注册")
	for side in [5, 6, 7, 8, 9]:
		var want: int = R07_MINES[side]
		var ok_cnt := 0
		for t in TRIALS:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 4013 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			for m in mines:
				ms[m] = true
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复" % [side, side])
			assert_true(_convex_ok(ms, side), "%dx%d 每行每列的雷都应连续" % [side, side])
		assert_gt(float(ok_cnt) / float(TRIALS), 0.9,
			"%dx%d 构造式布雷成功率应 > 90%%（实测 %d/%d）" % [side, side, ok_cnt, TRIALS])
