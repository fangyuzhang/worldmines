# test_z5_dengcha.gd —— Z5「等差行」单元测试（GUT）
# 覆盖：插件契约、各行雷数成等差数列（独立复算）、雷数守恒、成功率下界、
# **GDD §4.5 判别式实证**（N ≡ 0 mod gcd(R, R(R−1)/2)：5×5 要求 5 的倍数、6×6 要求 3 的倍数、
# 7×7 要求 7 的倍数、8×8 要求 4 的倍数——标准值 14/20/26 中的不可行项须回退）。
extends GutTest

const MOD_DIR := "res://demo/mods/z5_dengcha"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const TRIALS := 15


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	autofree(api)
	api.load_mod(MOD_DIR)


func _gcd(x: int, y: int) -> int:
	var a := absi(x)
	var b := absi(y)
	while b != 0:
		var t := b
		b = a % b
		a = t
	return maxi(a, 1)


func _arith_ok(mines: Array, n: int) -> bool:
	var cnt: Array = []
	for i in n:
		cnt.append(0)
	for m in mines:
		cnt[(m as Vector2i).y] = int(cnt[(m as Vector2i).y]) + 1
	if n < 2:
		return true
	var d: int = int(cnt[1]) - int(cnt[0])
	for i in n - 1:
		if int(cnt[i + 1]) - int(cnt[i]) != d:
			return false
	return true


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z5")
	assert_not_null(r, "z5 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "Z5 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "等差行", "名称应为「等差行」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


## GDD §4.5 判别式：N ≡ 0 (mod gcd(R, R(R−1)/2))。违反者必须返回空（不偷偷调平雷数）。
func test_discriminant_violations_rejected() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z5")
	assert_not_null(r, "z5 未注册")
	# 7×7 标准 20：gcd(7, 21) = 7，20 不是 7 的倍数 → 不可满足
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	assert_eq((r.call("place_mines", rng, 7, 7, 20) as Array).size(), 0,
		"7×7 标准 20 雷应不可满足（须回退 14/21）")
	# 8×8 标准 26：gcd(8, 28) = 4，26 不是 4 的倍数 → 不可满足
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 5151
	assert_eq((r.call("place_mines", rng2, 8, 8, 26) as Array).size(), 0,
		"8×8 标准 26 雷应不可满足（须回退 24/28）")
	# 5×5 标准 10：gcd(5, 10) = 5，10 是 5 的倍数 → 可行（GDD：四尺寸中唯一标准值可行者）
	var rng3 := RandomNumberGenerator.new()
	rng3.seed = 5152
	assert_eq((r.call("place_mines", rng3, 5, 5, 10) as Array).size(), 10,
		"5×5 标准 10 雷应可行（GDD 表：唯一标准值可行的尺寸）")


func test_place_mines_all_sizes() -> void:
	var r: Object = RuleRegistry.default().resolve(&"z5")
	assert_not_null(r, "z5 未注册")
	# 各尺寸取满足判别式的雷数（含回退值）
	var case := {5: 10, 6: 12, 7: 14, 8: 24, 9: 27}
	for side in [5, 6, 7, 8, 9]:
		var want: int = case[side]
		# 用例值必须真的满足判别式（自检）
		assert_eq(want % _gcd(side, side * (side - 1) / 2), 0,
			"%dx%d 用例雷数 %d 应满足判别式" % [side, side, want])
		var ok_cnt := 0
		for t in TRIALS:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 811 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			for m in mines:
				ms[m] = true
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复" % [side, side])
			assert_true(_arith_ok(mines, side), "%dx%d 各行雷数应成等差数列" % [side, side])
		assert_gt(float(ok_cnt) / float(TRIALS), 0.9,
			"%dx%d 构造式布雷成功率应 > 90%%（实测 %d/%d）" % [side, side, ok_cnt, TRIALS])
