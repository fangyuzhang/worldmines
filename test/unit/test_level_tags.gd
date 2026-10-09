# test_level_tags.gd —— 关卡归属标签（成就 / 雷达共用的唯一解析口径）
extends GutTest

const Tags := preload("res://core/level_tags.gd")


func test_parse_gen_and_lib_keys() -> void:
	var g := Tags.parse_key("gen://o1/8/3")
	assert_eq(str(g.get("mode", "")), "o1", "gen 键应解出 mode")
	assert_eq(int(g.get("size", 0)), 8, "gen 键应解出 size")
	assert_eq(int(g.get("idx", 0)), 3, "gen 键应解出 idx")
	assert_false(bool(g.get("lib", true)), "gen 键不是库键")

	var l := Tags.parse_key("lib://s3/12/normal/1")
	assert_eq(str(l.get("mode", "")), "s3", "lib 键应解出 mode")
	assert_eq(str(l.get("tier", "")), "normal", "lib 键应解出档位")
	assert_eq(int(l.get("idx", 0)), 1, "lib 键应解出 idx")
	assert_true(bool(l.get("lib", false)), "lib 键应标记为库键")


func test_parse_rejects_non_sequence() -> void:
	assert_true(Tags.parse_key("res://levels/iso_01.json").is_empty(), "非序列路径不是键")
	assert_true(Tags.parse_key("gen://o1/8").is_empty(), "字段不足应拒绝")
	assert_true(Tags.parse_any("iso_01.json").is_empty(), "手工关没有 mode 段")


func test_axes_for_mode() -> void:
	assert_eq(Tags.axes_for_mode("o1"), ["o1"], "单席观测")
	assert_eq(Tags.axes_for_mode("s3"), ["s3"], "单席结构")
	assert_eq(Tags.axes_for_mode("z5"), ["z5"], "单席守恒")
	assert_eq(Tags.axes_for_mode("o5x"), ["o5x"], "带 x 的观测席位")
	assert_eq(Tags.axes_for_mode("combo"), [] as Array[String], "未知模式不属于任何轴")


func test_axes_for_mode_handles_aliases() -> void:
	assert_eq(Tags.axes_for_mode("clock"), ["o8"], "clock 等价 O8")
	assert_eq(Tags.axes_for_mode("loopruns"), ["o10"], "loopruns 等价 O10")
	assert_eq(Tags.axes_for_mode("pf"), ["s1"], "pf 等价 S1")
	assert_eq(Tags.axes_for_mode("mx"), ["z1"], "mx 等价 Z1")
	assert_eq(Tags.axes_for_mode("rl"), ["z2"], "rl 等价 Z2")
	assert_eq(Tags.axes_for_mode("qd"), ["z3"], "qd 等价 Z3")


func test_axes_for_mixed_mode() -> void:
	var ax := Tags.axes_for_mode("o1_s3")
	assert_eq(ax.size(), 2, "混合档应同时命中两席")
	assert_true(ax.has("o1") and ax.has("s3"), "混合档应含两席")


func test_kind_of() -> void:
	assert_eq(Tags.kind_of("gen://o1/8/0"), Tags.KIND_OBS, "o 席属观测")
	assert_eq(Tags.kind_of("gen://s2/8/0"), Tags.KIND_STRUCT, "s 席属结构")
	assert_eq(Tags.kind_of("gen://z4/8/0"), Tags.KIND_CONSERVE, "z 席属守恒")
	assert_eq(Tags.kind_of("gen://o1_s2/8/0"), Tags.KIND_MIXED, "跨轴属混合")
	assert_eq(Tags.kind_of("gen://combo/8/0"), Tags.KIND_SPECIAL, "无轴属特殊")


func test_illusion_detection() -> void:
	assert_true(Tags.is_illusion("res://levels/iso_03.json"), "iso 属错觉策展")
	assert_true(Tags.is_illusion("res://levels/wormhole_02.json"), "虫洞属错觉策展")
	assert_false(Tags.is_illusion("res://levels/hex_01.json"), "蜂窝不是错觉策展")
	assert_false(Tags.is_illusion("gen://o1/8/0"), "生成关谈不上系列")


func test_axis_kinds_of_levels() -> void:
	var levels := {
		"gen://o1/8/0": {"cleared": true},
		"gen://o2/8/0": {"cleared": true},
		"gen://s1/8/0": {"cleared": true},
		"gen://z1/8/0": {"cleared": false},
		"gen://combo/8/0": {"cleared": true},
	}
	var k := Tags.axis_kinds_of_levels(levels)
	assert_eq(int(k["obs"]), 2, "应数出 2 种观测轴")
	assert_eq(int(k["struct"]), 1, "应数出 1 种结构轴")
	assert_eq(int(k["cons"]), 0, "未通关的守恒关不计")
	assert_eq(int(k["all"]), 3, "合计 3 种轴")
