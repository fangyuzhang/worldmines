# test_z2_xianglin.gd —— Z2「相邻行锁」单元测试（GUT）
# 覆盖：插件契约、相邻行雷数差绝对值恒为 1（独立复算）、雷数守恒、成功率下界、
# **GDD 奇偶性结论的实证**（6×6 的 R(R−1)/2=15 为奇 ⇒ N 必须为奇数：标准 14 应返回空、15 可行）。
extends GutTest

const MOD_DIR := "res://demo/mods/z2_xianglin"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const TRIALS := 20


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod(MOD_DIR)


func _rows_ok(mines: Array, rows: int) -> bool:
	var cnt: Array = []
	for i in rows:
		cnt.append(0)
	for m in mines:
		cnt[(m as Vector2i).y] = int(cnt[(m as Vector2i).y]) + 1
	for i in rows - 1:
		if absi(int(cnt[i + 1]) - int(cnt[i])) != 1:
			return false
	return true


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z2")
	assert_not_null(r, "z2 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "Z2 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "相邻行锁", "名称应为「相邻行锁」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


## GDD §4.5 的奇偶性结论实证：6×6 标准 14 雷**数学不可满足**（R(R−1)/2 = 15 为奇 ⇒ N 须为奇）。
func test_6x6_parity_infeasible_standard() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z2")
	assert_not_null(r, "z2 未注册")
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var mines: Array = r.call("place_mines", rng, 6, 6, 14)
	assert_eq(mines.size(), 0, "6×6 标准 14 雷应不可满足（奇偶性）——须由候选列表回退")
	# 回退到 15（奇数）应可行
	var ok15 := 0
	for t in 5:
		var rng2 := RandomNumberGenerator.new()
		rng2.seed = t * 31 + 7
		var m15: Array = r.call("place_mines", rng2, 6, 6, 15)
		if m15.size() == 15:
			ok15 += 1
			assert_true(_rows_ok(m15, 6), "6×6/15 雷应满足相邻行差为 1")
	assert_gt(ok15, 0, "6×6 回退到 15 雷（奇数）应可产出")


## 全尺寸：雷数守恒 + 相邻行差绝对值恒为 1 + 成功率下界。
func test_place_mines_all_sizes() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z2")
	assert_not_null(r, "z2 未注册")
	for side in [5, 7, 8, 9]:
		var want: int = R07_MINES[side]
		var ok_cnt := 0
		for t in TRIALS:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 1327 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			for m in mines:
				ms[m] = true
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复" % [side, side])
			assert_true(_rows_ok(mines, side), "%dx%d 相邻行雷数差应为 1" % [side, side])
		assert_gt(float(ok_cnt) / float(TRIALS), 0.9,
			"%dx%d 构造式布雷成功率应 > 90%%（实测 %d/%d）" % [side, side, ok_cnt, TRIALS])
