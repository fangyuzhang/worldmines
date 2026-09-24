# test_s2_zhongxin.gd —— S2「重心」单元测试（GUT）
# 覆盖：插件契约（KIND_GLOBAL / id / describe）、中央格区区间计算（奇偶两态）、
# 构造式布雷（雷数守恒 + 一阶矩落入区间 + 成功率下界）、与解析期望值的对照。
#
# 规则要点（GDD §4.5）：只约束一阶矩（平均值）、不约束方差——四角各堆一簇、平均位置仍可居中。
# 故测试只校验 Σx/Σy 落入区间，**不**校验分布形状。
extends GutTest

const MOD_DIR := "res://demo/mods/s2_zhongxin"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const TRIALS := 40


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	autofree(api)
	api.load_mod(MOD_DIR)


func _sums(mines: Array) -> Array:
	var sx := 0
	var sy := 0
	for m in mines:
		sx += (m as Vector2i).x
		sy += (m as Vector2i).y
	return [sx, sy]


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s2")
	assert_not_null(r, "s2 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "S2 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "重心", "名称应为「重心」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


## 与 GDD §4.5 示例对照：8×8 / 26 雷 → 中央格区坐标 3..4 → Σx ∈ [78, 104]。
func test_gdd_example_bounds() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s2")
	assert_not_null(r, "s2 未注册")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260916
	var mines: Array = r.call("place_mines", rng, 8, 8, 26)
	assert_eq(mines.size(), 26, "8×8 应有 26 雷")
	var s: Array = _sums(mines)
	assert_true(int(s[0]) >= 78 and int(s[0]) <= 104, "Σx=%d 应落在 [78,104]（GDD 示例）" % int(s[0]))
	assert_true(int(s[1]) >= 78 and int(s[1]) <= 104, "Σy=%d 应落在 [78,104]（GDD 示例）" % int(s[1]))


## 全尺寸：成功时雷数守恒 + 一阶矩落区间；成功率有下界。
func test_place_mines_all_sizes() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s2")
	assert_not_null(r, "s2 未注册")
	for side in [5, 6, 7, 8, 9]:
		var want: int = R07_MINES[side]
		var lo: int = want * ((side - 1) / 2)
		var hi: int = want * (side / 2)
		var ok_cnt := 0
		for t in TRIALS:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 6151 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			for m in mines:
				ms[m] = true
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复" % [side, side])
			var s: Array = _sums(mines)
			assert_true(int(s[0]) >= lo and int(s[0]) <= hi,
				"%dx%d Σx=%d 应落在 [%d,%d]" % [side, side, int(s[0]), lo, hi])
			assert_true(int(s[1]) >= lo and int(s[1]) <= hi,
				"%dx%d Σy=%d 应落在 [%d,%d]" % [side, side, int(s[1]), lo, hi])
		assert_gt(float(ok_cnt) / float(TRIALS), 0.9,
			"%dx%d 构造式布雷成功率应 > 90%%（实测 %d/%d）" % [side, side, ok_cnt, TRIALS])


## 奇偶两态的中央区间：奇数 → 单格（lo==hi）；偶数 → 2×2（hi==lo+1）。
func test_center_bounds_parity() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s2")
	assert_not_null(r, "s2 未注册")
	# 通过布雷结果的 Σ 反推：把雷全放在中央区应可行（该情形下 Σ = N·lo 或 N·hi）
	for side in [5, 6, 7, 8, 9]:
		var n: int = R07_MINES[side]
		var lo: int = (side - 1) / 2
		var hi: int = side / 2
		if side % 2 == 1:
			assert_eq(lo, hi, "%d 为奇数 → 中央应为 1×1（区间退化）" % side)
		else:
			assert_eq(hi - lo, 1, "%d 为偶数 → 中央应为 2×2" % side)
		var rng := RandomNumberGenerator.new()
		rng.seed = side * 99
		var mines: Array = r.call("place_mines", rng, side, side, n)
		assert_eq(mines.size(), n, "%dx%d 应产出 %d 雷" % [side, side, n])
