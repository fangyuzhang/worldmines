extends GutTest

## 主题化「容器底板」契约（2026-09-29）
##
## 起因：设置面板的内容区底板一直在吃 Godot 引擎默认的 `TabContainer/panel` 样式盒
## （不透明、近黑，bg_color ≈ Color(0.1,0.1,0.1,0.6)），它铺在浅色 `card()` 卡片之上 ⇒
## 正文被压到**实测 1.67:1**（`#444d5b` 压 `#607174`），整页设置项几乎读不出来。
## 口径见 `_pv/probe_skin_contrast.py`（取样框整块落在元素内部，不是压在边界上）。
##
## 为什么这类缺陷能活很久：
##   · 它不是"没上色"，而是"上了色的容器**里面**叠了一块没上色的底板"；
##   · 静态检查、既有单测、代码评审都只看"有没有设 font_color"，看不出叠层；
##   · CozyStyle 之前的主视觉是深色主题 —— 深色底 + 白字毫无异常，缺陷被深色主题藏住了；
##   · 它不是"错"，它是"引擎默认值"，看起来像是设计选择。
##
## 断言方式刻意选**渲染后的对比度**，而不是"某属性 == 某值"：
## 底板怎么实现都行，只要它与正文的对比度达标。这样以后换实现不会被测试绊住，
## 而"又叠了一块深色底板"这种回归一定会被抓住。

## WCAG 2.x：正文 AA = 4.5:1。与 _pv/analyze_ui_probe.py、test_theme_manager.gd 同口径。
const AA_BODY := 4.5

const PANEL := "res://ui/settings_panel.tscn"

var _saved: Dictionary = {}


func before_all() -> void:
	# 本文件会直接改 autoload ThemeManager（绕开 300ms tween），结束必须还原
	_saved = {
		"mode": ThemeManager.mode,
		"target": ThemeManager._target,
		"active": ThemeManager._active,
	}


func after_all() -> void:
	if not _saved.is_empty():
		ThemeManager.mode = _saved["mode"]
		ThemeManager._target = _saved["target"]
		ThemeManager._active = _saved["active"]


# ============================ 工具 ============================

func _use(m: String) -> void:
	ThemeManager.mode = m
	ThemeManager._target = ThemeManager._palette_for(m)
	ThemeManager._active = ThemeManager._target.duplicate()


func _theme_ids() -> Array:
	return ThemeManager.THEME_IDS.filter(func(x): return str(x) != "system")


func _settle(n: int = 10) -> void:
	for i in n:
		await get_tree().process_frame


func _find_first(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var hit := _find_first(c, cls)
		if hit != null:
			return hit
	return null


func _lin(u: float) -> float:
	return u / 12.92 if u <= 0.04045 else pow((u + 0.055) / 1.055, 2.4)


func _lum(c: Color) -> float:
	return 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b)


func _contrast(a: Color, b: Color) -> float:
	var la := _lum(a)
	var lb := _lum(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


func _hex(c: Color) -> String:
	return "#%02x%02x%02x" % [int(round(c.r * 255)), int(round(c.g * 255)), int(round(c.b * 255))]


func _mount_panel():
	var sp = load(PANEL).instantiate()
	add_child_autofree(sp)
	await _settle(12)
	return sp


# ============================ 断言 ============================

func test_settings_content_panel_is_themed_on_every_theme() -> void:
	## 逐主题（含 dark / light / 五套 CozyStyle）检查：
	##   ① TabContainer 必须有 `panel` 样式盒**覆盖**（没有覆盖 = 又吃引擎默认深色底板）；
	##   ② 底板色必须与正文色 ≥4.5:1。
	## 遍历全部主题是关键 —— 只测 CozyStyle 就无法证明 dark/light 没被改坏，
	## 只测 dark 就完全测不出这个缺陷（深色底下白字本来就是达标的）。
	var sp = await _mount_panel()
	var tabs := _find_first(sp, "TabContainer")
	assert_not_null(tabs, "设置面板里应有 TabContainer（结构变了？本测试要同步改）")

	var checked := 0
	for m: String in _theme_ids():
		_use(m)
		sp._apply_theme()   # 直接改 mode 不会发 theme_changed，手工刷一次
		assert_true(tabs.has_theme_stylebox_override("panel"),
			"%s：TabContainer 没有 `panel` 样式盒覆盖 ⇒ 内容区会退回引擎默认的深色底板" % m)
		var sb: StyleBox = tabs.get_theme_stylebox("panel")
		assert_not_null(sb, "%s：取不到 panel 样式盒" % m)

		var bg: Color = ThemeManager.card() if not (sb is StyleBoxFlat) else (sb as StyleBoxFlat).bg_color
		var fg: Color = ThemeManager.text()
		var r := _contrast(fg, bg)
		assert_gte(r, AA_BODY,
			"%s：内容区底板%s 压正文%s 只有 %.2f:1（需 ≥%.1f）"
			% [m, _hex(bg), _hex(fg), r, AA_BODY])
		checked += 1
	assert_eq(checked, _theme_ids().size(),
		"应逐主题检查（实得 %d / %d）" % [checked, _theme_ids().size()])


func test_content_panel_matches_the_outer_card() -> void:
	## 内容区底板必须**与外层 PanelContainer 同色** —— 否则会看到两条不同色的分层，
	## 那正是"引擎默认底板叠在卡片上"的可见征兆（也是本次缺陷的外观表现）。
	## 同色还能保证外层 10px 圆角不会被内层方角切掉。
	var sp = await _mount_panel()
	var tabs := _find_first(sp, "TabContainer")
	assert_not_null(tabs, "设置面板里应有 TabContainer")

	var checked := 0
	for m: String in _theme_ids():
		_use(m)
		sp._apply_theme()
		var inner: StyleBox = tabs.get_theme_stylebox("panel")
		assert_true(inner is StyleBoxFlat, "%s：内容区底板应为 StyleBoxFlat（便于取色）" % m)
		var outer: StyleBox = sp._panel.get_theme_stylebox("panel")
		assert_true(outer is StyleBoxFlat, "%s：外层卡片底板应为 StyleBoxFlat" % m)
		assert_eq((inner as StyleBoxFlat).bg_color, (outer as StyleBoxFlat).bg_color,
			"%s：内容区底板与外层卡片必须同色（否则出现两条分层）" % m)
		checked += 1
	assert_eq(checked, _theme_ids().size(), "应逐主题检查（实得 %d）" % checked)


func test_tab_strip_fonts_are_themed() -> void:
	## 页签条的字色也必须接管：选中/未选中/悬停三态在浅色底上靠引擎默认同样发灰，
	## 而"选中态看不出选的是哪个"是最典型的可用性缺陷（玩家找不到自己在哪一页）。
	var sp = await _mount_panel()
	var tabs := _find_first(sp, "TabContainer")
	assert_not_null(tabs, "设置面板里应有 TabContainer")

	for m: String in _theme_ids():
		_use(m)
		sp._apply_theme()
		for key: String in ["font_selected_color", "font_unselected_color", "font_hovered_color"]:
			assert_true(tabs.has_theme_color_override(key),
				"%s：页签条缺少 `%s` 覆盖 ⇒ 该态会退回引擎默认色" % [m, key])
		# 选中态字色压在内容区底板上必须达标（未选中态压在页面底色上同理）
		var sel: Color = tabs.get_theme_color("font_selected_color")
		var r := _contrast(sel, ThemeManager.card())
		assert_gte(r, AA_BODY,
			"%s：选中页签字色%s 压卡片底%s 只有 %.2f:1" % [m, _hex(sel), _hex(ThemeManager.card()), r])
