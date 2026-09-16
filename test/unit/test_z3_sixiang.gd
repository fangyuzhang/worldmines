# test_z3_sixiang.gd —— Z3「四象」单元测试（GUT）
# 覆盖：插件契约、四象限雷数相等（独立复算）、雷数守恒、成功率下界、
# **GDD §4.5 整除要求实证**（偶数盘 6×6 的 14 / 8×8 的 26 **不可满足**——须由候选列表回退）。
extends GutTest

const MOD_DIR := "res://demo/mods/z3_sixiang"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const TRIALS := 15


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod(MOD_DIR)


func _quad_counts(lv_mines: Array, n: int) -> Array:
	var cnt := [0, 0, 0, 0]
	for m in lv_mines:
		var qi := ConstraintEngine.quadrant_of(int(m["r"]), int(m["c"]), n, n)
		if qi >= 0:
			cnt[qi] = int(cnt[qi]) + 1
	return cnt


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z3")
	assert_not_null(r, "z3 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "Z3 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "四象", "名称应为「四象」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


## GDD §4.5：偶数盘无中轴吸收余数 → 雷数必须是 4 的倍数（标准 14 / 26 不可满足）。
func test_even_board_divisibility() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z3")
	assert_not_null(r, "z3 未注册")
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	assert_eq((r.call("place_mines", rng, 6, 6, 14) as Array).size(), 0,
		"6×6 标准 14 雷应不可满足（须回退 12/16）")
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 778
	assert_eq((r.call("place_mines", rng2, 8, 8, 26) as Array).size(), 0,
		"8×8 标准 26 雷应不可满足（须回退 24/28）")
	# 回退值应可行
	var rng3 := RandomNumberGenerator.new()
	rng3.seed = 779
	assert_eq((r.call("place_mines", rng3, 6, 6, 12) as Array).size(), 12, "6×6 回退 12 雷应可行")


func test_place_mines_all_sizes() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z3")
	assert_not_null(r, "z3 未注册")
	# 各尺寸用「实际可用雷数」（含回退）
	var case := {5: 10, 6: 12, 7: 20, 8: 24, 9: 32}
	for side in [5, 6, 7, 8, 9]:
		var want: int = case[side]
		var ok_cnt := 0
		for t in TRIALS:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 3079 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			var as_arr: Array = []
			for m in mines:
				ms[m] = true
				as_arr.append({"c": (m as Vector2i).x, "r": (m as Vector2i).y})
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复" % [side, side])
			var cnt := _quad_counts(as_arr, side)
			assert_true(int(cnt[0]) == int(cnt[1]) and int(cnt[1]) == int(cnt[2]) and int(cnt[2]) == int(cnt[3]),
				"%dx%d 四象限雷数应相等（实测 %s）" % [side, side, str(cnt)])
		assert_gt(float(ok_cnt) / float(TRIALS), 0.9,
			"%dx%d 构造式布雷成功率应 > 90%%（实测 %d/%d）" % [side, side, ok_cnt, TRIALS])
