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
	"res://tools/gen_wormhole_levels.gd",
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


# ==================== 暂存写盘机制（2026-09-23 审计）====================
#
# 四个生成器原来直接 FileAccess.open("res://levels/<file>", WRITE) 覆盖正式文件、
# 自校验失败再 remove —— 盘上原有的好文件被「覆盖后删除」，净结果永久丢失；批量在
# 后半程失败时还会留下半写批次（gen_shape_levels 有 TMP_DIR 机制，四家没有）。
# 现统一走 tools/level_staging.gd（写 res://levels/_staging/ → 校验 → 原子 rename）。

const STAGING := "res://tools/level_staging.gd"
const STAGING_USERS: Array = [
	"res://tools/gen_geo_levels.gd",
	"res://tools/gen_style_shape_levels.gd",
	"res://tools/gen_variant_shape_levels.gd",
	"res://tools/gen_iso_cubes_levels.gd",
	"res://tools/gen_wormhole_levels.gd",
]


func test_staging_module_and_users_compile() -> void:
	assert_not_null(load(STAGING), "暂存模块应能编译")
	for p in STAGING_USERS:
		assert_not_null(load(p), "%s 应能编译（暂存改造后）" % p)


func test_staging_users_write_through_staging() -> void:
	for p in STAGING_USERS:
		var src := _read(p)
		assert_ne(src, "", "应能读到 %s" % p)
		assert_true(src.contains("LevelStaging.write_text"), "%s 的写盘应走暂存" % p)
		assert_true(src.contains("LevelStaging.promote"), "%s 应原子转正" % p)
		assert_false(src.contains("FileAccess.open(path, FileAccess.WRITE)"),
			"%s 不应再直接覆盖正式文件（失败会丢原文件）" % p)


## 读文本文件（源码级断言用）。
func _read(p: String) -> String:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


# ==================== 纹理徽记与产物缩进（2026-09-23 审计续）====================

func test_shape_generators_declare_texture() -> void:
	# 产物带 palette.texture 的族，生成器必须写该字段——否则重跑会把纹理徽记悄悄丢掉
	#（iso_cubes 实测：一次重跑让 5 个文件各少一行；geo 同类风险已按 kind 回填）。
	# style 族待理清（10 关空值 + 3 关变体值混入，见其文件头警示），暂不列入。
	for p in ["res://tools/gen_geo_levels.gd", "res://tools/gen_iso_cubes_levels.gd"]:
		var src := _read(p)
		assert_ne(src, "", "应能读到 %s" % p)
		assert_true(src.contains('pal["texture"]'),
			"%s 应写 palette.texture（否则重跑丢纹理徽记）" % p)


func test_product_json_keeps_two_space_indent() -> void:
	# 2026-09-23 内两次出现「levels/*.json 被外部进程改写成 1 空格缩进」（内容零变化、
	# 纯格式噪音，波及 47~108 个文件）。这条门禁在它再发生时立刻红灯，省得又在 git diff 里翻找。
	var names := ["classic_01.json", "holed_01.json", "hex_01.json", "iso_01.json", "art_target.json", "ani_turtle.json"]
	var checked := 0
	for n in names:
		var src := _read("res://levels/" + n)
		if src == "":
			continue
		var lines := src.split("\n")
		assert_gt(lines.size(), 2, "%s 应有内容" % n)
		if lines.size() > 1:
			assert_true(str(lines[1]).begins_with("  \""),
				"%s 第 2 行应以 2 空格缩进开头（实得 %s）——1 空格说明被外部进程重写过" % [n, str(lines[1]).left(24)])
			checked += 1
	assert_gt(checked, 0, "应至少检查到一个关卡文件")


# ==================== 纹理徽记：规则单点 ↔ 登记表 ↔ 产物（2026-09-23 审计续）====================
#
# 徽记规则现由 tools/texture_marks.gd 一张表唯一提供（生成器写盘前调用 resolve）。
# 这两个用例守住「表 ↔ 渲染登记表」与「表 ↔ 全部产物」两条缝：
#   · 表里声明的每个值都必须登记在 ui/board_view.gd 的 TEXTURE_MARKS（否则玩家看不到）；
#   · 每个带变体的关卡，其 palette.texture 必须等于表的解析结果（新增变体/族自动覆盖）。

const MARKS := "res://tools/texture_marks.gd"


func test_texture_marks_declared_values_are_registered() -> void:
	var marks: Variant = load(MARKS)
	assert_not_null(marks, "纹理规则模块应能编译")
	if marks == null:
		return
	var declared: Array = marks.call("declared_values")
	assert_gt(declared.size(), 0, "规则表应声明至少一个徽记")
	var bv := _read("res://ui/board_view.gd")
	assert_ne(bv, "", "应能读到 ui/board_view.gd（渲染侧登记表）")
	for v in declared:
		assert_true(bv.contains('"%s"' % str(v)),
			"徽记「%s」应登记在 board_view.TEXTURE_MARKS" % str(v))


func test_all_variant_products_match_texture_marks() -> void:
	var marks: Variant = load(MARKS)
	if marks == null:
		return
	var d := DirAccess.open("res://levels")
	assert_not_null(d, "应能打开 res://levels")
	if d == null:
		return
	var checked := 0
	for fn in d.get_files():
		if not fn.ends_with(".json"):
			continue
		var src := _read("res://levels/" + fn)
		if src == "":
			continue
		var parsed: Variant = JSON.parse_string(src)
		if not (parsed is Dictionary):
			continue
		var lv: Dictionary = parsed
		var gl: Variant = lv.get("global_rules", [])
		if not (gl is Array) or (gl as Array).is_empty():
			continue
		var variant := str((gl as Array)[0])
		if not bool(marks.call("variant_has_mark", variant)):
			continue          # 该变体没有专属徽记（z1/z3/z4/z5 等）
		var want := str(marks.call("resolve", "", variant, ""))
		var pal: Variant = lv.get("palette", {})
		var got := str((pal as Dictionary).get("texture", "")) if pal is Dictionary else ""
		assert_eq(got, want, "%s（变体 %s）：产物徽记应与规则表一致" % [fn, variant])
		checked += 1
	assert_gt(checked, 0, "应至少核到一个带变体的关")
