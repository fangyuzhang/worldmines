# test_theme_manager.gd —— ThemeManager（全工程唯一合法色源）单元测试
#
# 2026-09-26 补：此前零直接测试（审计盲区清单里视觉依赖最重的文件）。
# 除常规行为外，重点用 **WCAG 对比度公式**锁定两个无障碍取色接口：
#   danger_text()（正文 ≥4.5:1）与 board_grid()（格线非文本 ≥3:1）——
#   这类「看起来对但数字不达标」的问题靠肉眼审不出来。
extends GutTest

const TM := preload("res://ui/theme_manager.gd")

# ---- WCAG 相对亮度 / 对比度 ----
func _lin(u: float) -> float:
	return u / 12.92 if u <= 0.04045 else pow((u + 0.055) / 1.055, 2.4)

func _lum(c: Color) -> float:
	return 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b)

func _contrast(a: Color, b: Color) -> float:
	var hi: float = max(_lum(a), _lum(b))
	var lo: float = min(_lum(a), _lum(b))
	return (hi + 0.05) / (lo + 0.05)

## 半透明前景压在不透明底上的实际渲染色（alpha 混合）
func _blend(fg: Color, bg: Color) -> Color:
	return Color(
		fg.a * fg.r + (1.0 - fg.a) * bg.r,
		fg.a * fg.g + (1.0 - fg.a) * bg.g,
		fg.a * fg.b + (1.0 - fg.a) * bg.b)

func _fresh() -> Node:
	var t: Node = TM.new()
	add_child_autofree(t)
	return t

# ---------- 1. 色板结构 ----------

func test_dark_and_light_share_identical_keys():
	var dk: Dictionary = TM._DARK
	var lt: Dictionary = TM._LIGHT
	assert_eq(dk.keys().size(), lt.keys().size(), "两主题色板键数应一致（漂移=某主题缺色）")
	for k in dk.keys():
		assert_has(lt, k, "亮色板缺键: %s" % k)
	var od: Dictionary = TM._OVERLAY_DARK
	var ol: Dictionary = TM._OVERLAY_LIGHT
	assert_eq(od.keys().size(), ol.keys().size(), "遮罩色板键数应一致")
	for k in od.keys():
		assert_has(ol, k, "亮遮罩缺键: %s" % k)

func test_number_palettes_are_8_valid_colors():
	# 注意：不能用 TM.get("_NUM_DARK") —— get() 是实例方法，类上直接调用是编译错误
	for arr_pair in [["dark", TM._NUM_DARK], ["light", TM._NUM_LIGHT]]:
		var arr: Array = arr_pair[1]
		assert_eq(arr.size(), 8, "%s 应为 8 个（线索 1~8）" % arr_pair[0])
		var seen := {}
		for c in arr:
			assert_true(c is Color, "%s 元素应为 Color" % arr_pair[0])
			assert_false(seen.has(c), "%s 出现重复色（相邻数字同色会无法区分）" % arr_pair[0])
			seen[c] = true

# ---------- 2. 取色接口 ----------

func test_palette_for_applies_overlay_and_ignores_unknown_skin_keys():
	var t = _fresh()
	t._skin_colors = {"bg": Color.RED, "not_a_key": Color.GREEN}
	var p: Dictionary = t._palette_for("dark")
	assert_eq(p["bg"], Color.RED, "已知键应被皮肤覆盖")
	assert_false(p.has("not_a_key"), "未知键必须被忽略（防损坏的皮肤包崩掉色源）")
	assert_eq(p["card"], TM._DARK.card, "未覆盖键保持内置")

func test_getters_fall_back_to_dark_when_active_empty():
	var t = _fresh()
	assert_eq(t.bg(), TM._DARK.bg)
	assert_eq(t.text(), TM._DARK.text)
	assert_eq(t.grid_line(), TM._DARK.grid_line)
	assert_eq(t.mine_body(), TM._OVERLAY_DARK.mine_body)

func test_number_out_of_range_falls_back_to_text():
	var t = _fresh()
	t.mode = "dark"
	t._active = t._palette_for("dark")
	assert_eq(t.number(0), t.text(), "0=空白格，不入数字色")
	assert_eq(t.number(9), t.text(), "9 超界，回退文字色")
	assert_eq(t.number(1), TM._NUM_DARK[0])
	assert_eq(t.number(8), TM._NUM_DARK[7])

func test_skin_number_override_takes_precedence():
	var t = _fresh()
	var custom: Array = []
	for i in range(8):
		custom.append(Color(1.0, 0.5, 0.0, 1.0 - i * 0.09))
	t.apply_skin("my_skin", {}, custom, "dark")
	assert_eq(t.skin_id, "my_skin")
	assert_eq(t.number(3), custom[2], "皮肤数字色优先于内置")

func test_clear_skin_restores_builtin_palette():
	var t = _fresh()
	t._skin_colors = {"bg": Color.RED}
	t.apply_skin("my_skin", {"bg": Color.RED}, [], "dark")
	t.clear_skin("light")
	assert_eq(t.skin_id, "", "清除后 skin_id 归空")
	assert_eq(t._target["bg"], TM._LIGHT.bg, "清除皮肤后底版切到指定内置主题")

func test_transition_ends_exactly_on_target_palette():
	var t = _fresh()
	t.mode = "light"
	t._retarget()   # 300ms lerp 过渡
	await wait_seconds(0.5)
	assert_eq(t._active["bg"], TM._LIGHT.bg,
		"过渡终态必须**精确**等于目标色板——lerp 逐步逼近的残留误差会变成永久色偏")

# ---------- 3. WCAG 对比度（无障碍取色接口的硬指标） ----------

func test_danger_text_meets_wcag_aa_on_both_themes():
	var t = _fresh()
	for m in ["dark", "light"]:
		t.mode = m
		t._active = t._palette_for(m)
		var r: float = _contrast(t.danger_text(), t.bg())
		assert_gt(r, 4.5, "%s 模式 danger_text 压 bg = %.2f:1，WCAG AA 正文要求 ≥4.5:1" % [m, r])

func test_board_grid_meets_non_text_contrast_on_both_themes():
	# board_grid 是半透明线，实际渲染是 alpha 混合 → 必须按**混合后的颜色**算对比
	var t = _fresh()
	for m in ["dark", "light"]:
		t.mode = m
		t._active = t._palette_for(m)
		var blended: Color = _blend(t.board_grid(), t.cell_hidden())
		var r: float = _contrast(blended, t.cell_hidden())
		assert_gt(r, 3.0, "%s 模式 board_grid 混合后压 cell_hidden = %.2f:1，非文本要求 ≥3:1" % [m, r])

func test_text_on_bg_meets_wcag_aa_on_both_themes():
	var t = _fresh()
	for m in ["dark", "light"]:
		t.mode = m
		t._active = t._palette_for(m)
		var r: float = _contrast(t.text(), t.bg())
		assert_gt(r, 4.5, "%s 模式 text 压 bg = %.2f:1，正文 ≥4.5:1" % [m, r])
