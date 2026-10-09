# test_theme_marks.gd —— 主题配色单一事实源的契约（2026-09-24）
#
# 背景：盘点发现「生成器重跑会把 theme 抹掉」——五个生成器写 palette 时只写手写 RGB
# 底盘、不带 theme，于是凡被重跑碰过的关卡主题都退化成同一套灰紫（实测 s6/s7/z2 整族缺失、
# s2 混着三种值）。修法是照 texture_marks.gd 的范式立一个 tools/theme_marks.gd，
# 生成器与门禁都从同一处读。
#
# 本测试锁四件事：
#   ① 表本身合法：声明的色码都必须是 PaletteColor 九色之一；
#   ② resolve 优先级：explicit > variant > kind；
#   ③ apply 的**核心语义**：删掉七个短路键（不删则 theme 被逐键短路，等于白写）、
#      保留 groups/texture/自定义键、不改入参、解析不出主题时逐字返回；
#   ④ 全库门禁：凡变体关的 palette 都必须是 theme 驱动形态。
extends GutTest

const ThemeMarks := preload("res://tools/theme_marks.gd")


func test_declared_values_are_valid_color_codes() -> void:
	for code: String in ThemeMarks.declared_values():
		assert_true(PaletteColor.BASE.has(code), "声明的主题色码必须在九色板里：%s" % code)


func test_resolve_priority_explicit_over_variant_over_kind() -> void:
	assert_eq(ThemeMarks.resolve("PINK", "s1", "hex"), "PINK", "显式声明优先")
	assert_eq(ThemeMarks.resolve("", "s1", "hex"), "RED", "其次变体轴")
	assert_eq(ThemeMarks.resolve("", "", "hex"), "BLUE", "再次形状族 kind")
	assert_eq(ThemeMarks.resolve("", "", ""), "", "都解析不出 → 不给主题")


func test_apply_strips_shortcut_keys_and_keeps_extras() -> void:
	var pal := {
		"tile": [127, 127, 127], "background": [20, 0, 35], "tile_border": [200, 200, 200],
		"groups": {"A": [1, 2, 3]}, "texture": "weave", "custom_future_key": 1,
	}
	var out: Dictionary = ThemeMarks.apply(pal, "", "s1", "grid")
	assert_eq(str(out.get("theme", "")), "RED", "应写入解析出的主题")
	for k: String in ThemeMarks.SHORTCUT_KEYS:
		assert_false(out.has(k), "短路键 %s 必须被删掉（留着会把 theme 逐键短路）" % k)
	assert_true(out.has("groups"), "groups 必须保留（分色雷数计数器的数据源）")
	assert_true(out.has("texture"), "texture 必须保留（识别徽记）")
	assert_eq(int(out.get("custom_future_key", 0)), 1, "未知自定义键也应保留")
	# 入参不得被修改（生成器可能复用同一份底盘常量）
	assert_true(pal.has("tile"), "apply 不得修改入参：应返回新字典")


func test_apply_is_noop_when_no_theme_resolves() -> void:
	var pal := {"tile": [1, 2, 3]}
	var out: Dictionary = ThemeMarks.apply(pal, "", "", "")
	assert_eq(out, pal, "解析不出主题 → 逐字返回入参（普通矩形关的 palette 不该被动）")


func test_is_theme_driven() -> void:
	assert_true(ThemeMarks.is_theme_driven({"theme": "RED", "groups": {}}), "有 theme 且无短路键")
	assert_false(ThemeMarks.is_theme_driven({"groups": {}}), "无 theme → 非 theme 驱动")
	assert_false(ThemeMarks.is_theme_driven({"theme": "RED", "tile": [0, 0, 0]}),
		"有 theme 但残留短路键 → 不算 theme 驱动（theme 会被短路，等于没写）")


func test_all_shape_levels_are_theme_driven() -> void:
	## 全库门禁：**所有异形关**（不只变体关）的 palette 都必须是 theme 驱动形态。
	##
	## 为什么从"只查变体关"扩到全部：实测漏过一次 —— 补齐脚本只处理带 global_rules 的
	## 变体关，于是 27 个**纯形状关**（girih 3 + sty_hex 8 + sty_sq 12 + sty_t488 4）
	## 整批没有 theme、退回手写 RGB 底盘，看起来与别的盘一个色（正是"每关雷同"的残留），
	## 而旧版门禁对它们完全不设防。
	##
	## 唯一豁免：daisy_chain（原版复刻关，有意保留手写配色，见 test_daisy_chain.gd）。
	const EXEMPT: Array[String] = ["daisy_chain.json"]
	var bad: Array[String] = []
	var checked := 0
	for path in LevelLoader.list_levels():
		if not FileAccess.file_exists(path):
			continue
		if EXEMPT.has(path.get_file()):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var d: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if not (d is Dictionary):
			continue
		var lv: Dictionary = d
		var topo: Variant = lv.get("topology", null)
		if not (topo is Dictionary) or (topo as Dictionary).is_empty():
			continue                     # 矩形经典关：无 palette 也合规
		var pal: Variant = lv.get("palette", null)
		if pal == null:
			continue                     # 不带 palette 的异形关走主题色回退，合规
		if not (pal is Dictionary):
			bad.append(path.get_file())
			continue
		checked += 1
		if not ThemeMarks.is_theme_driven(pal):
			bad.append(path.get_file())
	assert_gt(checked, 0, "应至少检查到一个带 palette 的异形关")
	assert_eq(bad.size(), 0,
		"以下异形关的 palette 不是 theme 驱动（丢了 theme 或残留短路键，会与别的盘同色）：%s" % str(bad))


func test_no_generator_writes_palette_without_theme_marks() -> void:
	## 结构性门禁：五个生成器的写盘路径必须经过 ThemeMarks.apply（防「新写的生成器又忘了」）。
	## 用源码文本检查而非运行期检查 —— 生成器是离线工具，运行期测不到。
	var files := [
		"res://tools/gen_shape_levels.gd", "res://tools/gen_style_shape_levels.gd",
		"res://tools/gen_geo_levels.gd", "res://tools/gen_iso_cubes_levels.gd",
		"res://tools/gen_variant_shape_levels.gd", "res://tools/gen_wormhole_levels.gd",
	]
	var missing: Array[String] = []
	for p in files:
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null:
			missing.append(p + "(读不到)")
			continue
		var src := f.get_as_text()
		f.close()
		if not src.contains("ThemeMarks.apply("):
			missing.append(p.get_file())
	assert_eq(missing.size(), 0,
		"以下生成器没有通过 ThemeMarks.apply 写 palette（重跑会丢 theme）：%s" % str(missing))
