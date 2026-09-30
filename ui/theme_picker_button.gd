extends Button
## 常驻主题切换按钮（2026-09-30）：HUD 与选关页共用的自包含组件。
##
## 自带：调色板图标（Icons.skin 白模，随按钮 icon 色乘色）、PopupPanel 主题列表、
## ThemeManager/SettingsManager 联动、随 theme_changed 实时刷面板样式与当前高亮
##（分层过渡期间面板颜色跟着渐变）。
##
## 用法（宿主只负责定位与命名）：
##   var tp := ThemePickerScript.new()
##   tp.name = "SkinBtn"
##   host.add_child(tp)
## 图标样式在 _ready 里走 UiTheme.style_icon_button（与两处宿主的既有图标钮同口径）；
## 宿主的 icon_bar 批刷（level_select._apply_theme）不会再换图标（tex=null 保留原 icon）。
##
## 为什么抽组件：主题面板逻辑原先只活在 HUD 里，选关页没有换肤入口（用户需求：
## 常驻按钮）。抽成组件后 HUD 删 ~80 行、两处单一事实源。

## ⚠️ ui_icons.gd 刻意不声明 class_name（headless 下新全局类不在 .godot 缓存，
## 见工程坑表 #26）——调用方一律走 preload，本组件遵守同一条工程纪律。
const Icons := preload("res://ui/ui_icons.gd")

var _panel: PopupPanel
var _sb: StyleBoxFlat
var _list: VBoxContainer


func _init() -> void:
	icon = Icons.skin()
	expand_icon = true
	tooltip_text = "切换主题"
	focus_mode = Control.FOCUS_ALL
	pressed.connect(_toggle_panel)
	ThemeManager.theme_changed.connect(_refresh_theme_followups)


func _ready() -> void:
	# 与 HUD/_add_icon_button、level_select/_make_icon_button 同一条尺寸口径：
	# 40×40 最小尺寸 —— **容器布局下必须显式声明**：expand_icon=true 时图标不计入
	# 最小尺寸，HBox 会把按钮压到只剩内边距（18px 宽 ⇒ 内容区 0 ⇒ 图标不可见，
	# 2026-09-30 选关页实测）。HUD 不在容器里所以没暴露。
	custom_minimum_size = Vector2(40, 40)
	# 与两者同一条样式口径：图标按钮专用对称内边距 + 图标色随主题文字色
	#（白模 SVG 被它乘色）。
	UiTheme.style_icon_button(self)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color",
			"icon_focus_color", "icon_disabled_color"]:
		add_theme_color_override(state, ThemeManager.text())


## 面板开合。位置：右缘与按钮右缘对齐、顶在按钮下方 6px（往左长，不会出屏）。
func _toggle_panel() -> void:
	if _panel != null and is_instance_valid(_panel) and _panel.visible:
		_panel.hide()
		return
	_ensure_panel()
	_style_panel()
	_rebuild_list()
	_panel.reset_size()
	var br := get_global_rect()
	_panel.position = Vector2(br.end.x - _panel.size.x, br.end.y + 6.0)
	_panel.popup()


func _ensure_panel() -> void:
	if _panel != null and is_instance_valid(_panel):
		return
	_panel = PopupPanel.new()
	_sb = StyleBoxFlat.new()
	_sb.set_corner_radius_all(12)
	_sb.corner_detail = 16
	_sb.content_margin_left = 8.0
	_sb.content_margin_right = 8.0
	_sb.content_margin_top = 8.0
	_sb.content_margin_bottom = 8.0
	_sb.shadow_size = 12
	_sb.shadow_offset = Vector2(0, 4)
	_panel.add_theme_stylebox_override("panel", _sb)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	_panel.add_child(_list)
	_overlay_host().add_child(_panel)
	_panel.hide()   # Window 默认 visible=true，不显式隐藏会立刻弹出


func _style_panel() -> void:
	if _sb == null:
		return
	_sb.bg_color = ThemeManager.card()
	_sb.border_color = ThemeManager.grid_line()
	_sb.set_border_width_all(1)
	_sb.shadow_color = ThemeManager.shadow(ThemeManager.bg(), ThemeManager.SHADOW_DROP_MAT)


func _rebuild_list() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	var cur: String = SettingsManager.theme_mode
	# 【2026-09-30 图标化】面板头 = 调色板小图标 + 标题（TextureRect.self_modulate 乘主题次级色）
	var head_row := HBoxContainer.new()
	head_row.add_theme_constant_override("separation", 6)
	head_row.alignment = BoxContainer.ALIGNMENT_CENTER
	var head_ic := TextureRect.new()
	head_ic.texture = Icons.skin()
	head_ic.custom_minimum_size = Vector2(16, 16)
	head_ic.stretch_mode = TextureRect.STRETCH_SCALE
	head_ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	head_ic.self_modulate = ThemeManager.text_secondary()
	head_row.add_child(head_ic)
	var head := Label.new()
	head.text = "切换主题"
	head.add_theme_font_size_override("font_size", 14)
	head.add_theme_color_override("font_color", ThemeManager.text_secondary())
	head_row.add_child(head)
	_list.add_child(head_row)
	for id: String in ThemeManager.THEME_IDS:
		var b := Button.new()
		b.text = ("✓  " + ThemeManager.theme_label(id)) if id == cur else ThemeManager.theme_label(id)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_ALL
		b.custom_minimum_size = Vector2(168, 34)
		b.pressed.connect(_on_theme_pick.bind(id))
		UiTheme.style_button(b)
		if id == cur:
			b.add_theme_color_override("font_color", ThemeManager.accent())
			b.add_theme_color_override("font_hover_color", ThemeManager.accent())
		_list.add_child(b)


## 分层过渡期间面板开着时，样式与当前高亮逐帧跟随（theme_changed 每步广播）。
func _refresh_theme_followups() -> void:
	if _panel == null or not is_instance_valid(_panel) or not _panel.visible:
		return
	_style_panel()
	_rebuild_list()


## 点选主题：收面板 → 持久化切换。过渡由 ThemeManager 分层过渡承担，
## 棋盘/全页经 theme_changed 逐帧重绘。
func _on_theme_pick(id: String) -> void:
	if _panel != null and is_instance_valid(_panel):
		_panel.hide()
	if id == SettingsManager.theme_mode:
		return
	SettingsManager.set_theme_mode(id)


## Popup 的宿主：current_scene → 父节点 → self（与 HUD._overlay_host 同口径；
## 选关页/HUD 都是场景根的直接子节点，通常落 current_scene）。
func _overlay_host() -> Node:
	var scene := get_tree().current_scene
	if scene != null:
		return scene
	var parent := get_parent()
	return parent if parent != null else self
