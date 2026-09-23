# test_gen_param_parity.gd —— 生成器参数与规范源的一致性门禁（2026-09-23 审计）
#
# 背景：审计发现生成器把「峰值下限」这类参数**手抄**成常量（gen_geo_levels /
# gen_iso_cubes_levels 的 MIN_PEAK := 2，注释自称「= core/difficulty.gd 普通档下限」），
# core 改了档位窗口它们不会联动——正是 octopus「SPEC ↔ 产物脱节」那类事故的温床。
#
# 2026-09-23 起两处改为**直接引用** Difficulty.PEAK_WINDOWS（规范源）。
# 本测试守住两件事：
#   ① 工具脚本能编译 —— 它们以前只在 CLI（-s）跑时才编译，语法/常量表达式错误在测试里
#      是完全的盲区（这次改 const 引用正好是这类改动，必须有人盯）；
#   ② MIN_PEAK 的值与 Difficulty.tier_range("easy").x 一致 —— 若哪天有人把它改回手抄
#      数字，core 改窗口时这里会红灯。
extends GutTest

const GEN_FILES: Array = [
	"res://tools/gen_geo_levels.gd",
	"res://tools/gen_iso_cubes_levels.gd",
]


func test_generators_compile() -> void:
	for p in GEN_FILES:
		var s: Variant = load(p)
		assert_not_null(s, "%s 应能编译（const 表达式非法 / 语法错会在这里暴露）" % p)


func test_min_peak_matches_difficulty_easy_lower_bound() -> void:
	var want := Difficulty.tier_range("easy").x
	assert_gt(want, 0, "前置：easy 下沿应为正数（core 若改窗口，本测试跟着验）")
	for p in GEN_FILES:
		var s: Variant = load(p)
		if s == null:
			continue    # 编译失败由上一个测试报
		var consts: Dictionary = (s as Script).get_script_constant_map()
		assert_true(consts.has("MIN_PEAK"), "%s 应有 MIN_PEAK 常量" % p)
		if consts.has("MIN_PEAK"):
			assert_eq(int(consts["MIN_PEAK"]), want,
				"%s 的 MIN_PEAK 应等于 Difficulty.tier_range(\"easy\").x（改回手抄数字会在 core 改窗口时漂移）" % p)
