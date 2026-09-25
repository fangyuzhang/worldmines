# ui_theme.gd —— 统一 UI 样式与悬停微交互（class_name UiTheme）
# 悬停浮动效果：阴影（0 4px 24px rgba(0,0,0,0.4)）+ 边框变强调色 + 背景稍亮
# + pivot 居中的轻微 scale 抬起（0.2s 过渡，≤1.15 倍）。
# 注：Godot Container 布局下 translateY 会被布局覆盖，故用 scale 表达「抬起」，
# 视觉等价且不破坏布局。所有取色经 ThemeManager。
class_name UiTheme

const HOVER_SHADOW := Color(0, 0, 0, 0.4)
const SHADOW_OFFSET := Vector2(0, 4)
const SHADOW_SIZE := 12

## 按钮内边距（左右 / 上下）。
## 中文字形接近方块，且字体行高自带额外留白——沿用主题默认内边距会出现
##「左右贴死文字、上下空荡」的失衡。左右取上下两倍以抵消行高影响，视觉均衡。
const BTN_PAD_X := 16
const BTN_PAD_Y := 8


## 统一按钮样式 + 悬停浮动（scale 1.03 ≈ 2px 抬起感）。
static func style_button(btn: Button) -> void:
	var normal := StyleBoxFlat.new()
	_set_pad(normal)
	normal.bg_color = ThemeManager.card()
	normal.set_corner_radius_all(6)
	normal.set_border_width_all(1)
	normal.border_color = ThemeManager.grid_line()
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_color_override("font_color", ThemeManager.text())

	var hover := StyleBoxFlat.new()
	_set_pad(hover)
	hover.bg_color = ThemeManager.card().lightened(0.06)
	hover.set_corner_radius_all(6)
	hover.set_border_width_all(1)
	hover.border_color = ThemeManager.accent()
	hover.shadow_color = HOVER_SHADOW
	hover.shadow_size = SHADOW_SIZE
	hover.shadow_offset = SHADOW_OFFSET
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_color_override("font_hover_color", ThemeManager.text())

	var pressed := StyleBoxFlat.new()
	_set_pad(pressed)
	pressed.bg_color = ThemeManager.accent()
	pressed.set_corner_radius_all(6)
	pressed.set_border_width_all(1)
	pressed.border_color = ThemeManager.accent()
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_color_override("font_pressed_color", ThemeManager.text())

	# 键盘焦点样式（2026-09-25 无障碍审计）：与 hover 同款但描边**更粗** —— 焦点必须
	# 比悬停更显眼（键盘用户全靠它定位）。此前没有 focus 样式 ⇒ 聚焦时会落到引擎默认
	# 焦点框（浅色细线，与项目深色主题格格不入）。
	var focus_sb := StyleBoxFlat.new()
	_set_pad(focus_sb)
	focus_sb.bg_color = ThemeManager.card().lightened(0.06)
	focus_sb.set_corner_radius_all(6)
	focus_sb.set_border_width_all(2)
	focus_sb.border_color = ThemeManager.accent()
	btn.add_theme_stylebox_override("focus", focus_sb)
	btn.add_theme_color_override("font_focus_color", ThemeManager.text())

	bind_hover(btn, 1.03)


## 应用均衡内边距（normal/hover/pressed 三态共用，避免切换时按钮尺寸跳动）。
static func _set_pad(sb: StyleBoxFlat) -> void:
	sb.content_margin_left = BTN_PAD_X
	sb.content_margin_right = BTN_PAD_X
	sb.content_margin_top = BTN_PAD_Y
	sb.content_margin_bottom = BTN_PAD_Y


## 色标（圆形/方形色块）：悬停 scale 1.15 放大，不浮动；选中态 accent 边框。
static func style_swatch(sw: Button, color: Color, selected: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(4)
	if selected:
		sb.set_border_width_all(2)
		sb.border_color = ThemeManager.accent()
	else:
		sb.set_border_width_all(1)
		sb.border_color = ThemeManager.grid_line()
	sw.add_theme_stylebox_override("normal", sb)
	sw.add_theme_stylebox_override("hover", sb)
	sw.add_theme_stylebox_override("pressed", sb)
	sw.add_theme_stylebox_override("focus", sb)
	bind_hover(sw, 1.15)


## 绑定 hover 抬起：进入 scale 到目标，离开回 1.0（0.2s ease-out，不超过 0.3s）。
static func bind_hover(control: Control, scale_to: float) -> void:
	if control.has_meta("_ui_hover_lift"):
		return
	control.set_meta("_ui_hover_lift", true)
	control.mouse_entered.connect(func(): _lift_to(control, scale_to))
	control.mouse_exited.connect(func(): _lift_to(control, 1.0))


## 两点修正（原实现的真实缺陷）：
##   ① 每次进出都 create_tween()：快速划过会留下多个同目标同属性的 tween 同时驱动 scale，
##      谁后写谁生效 → 抖动甚至卡在非 1.0 的缩放上。现先 kill 掉本控件上的旧 tween 再开新的。
##   ② pivot_offset 原先只在 mouse_entered 那一刻按当时 size 取；换页/改字号后布局一变，
##      缩放就不再绕中心（表现为斜向漂移）。改为动画开始时才取当前 size。
static func _lift_to(control: Control, scale_to: float) -> void:
	if not is_instance_valid(control):
		return
	# get_meta 在键不存在时会打印 ERROR（即使传了 default）→ 先 has_meta 判断，
	# 否则调试器每次首次悬停都刷一条「no 'meta' values with the key '_ui_hover_tween'」。
	if control.has_meta("_ui_hover_tween"):
		var old: Tween = control.get_meta("_ui_hover_tween")
		if old != null and old.is_valid():
			old.kill()
	control.pivot_offset = control.size * 0.5
	var tw := control.create_tween()
	tw.set_trans(Tween.TRANS_QUAD)
	tw.set_ease(Tween.EASE_OUT)
	tw.tween_property(control, "scale", Vector2(scale_to, scale_to), 0.2)
	control.set_meta("_ui_hover_tween", tw)
