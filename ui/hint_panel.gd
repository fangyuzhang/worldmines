# hint_panel.gd —— 提示浮动窗口（透明无痕贴纸 + 点击唤醒调整 + 5 秒自动无痕）
# 无痕态（默认 / 5 秒后）：仅文字可见，无边框、无背景、无阴影（贴纸式浮层）。
# 点击文字 → 唤醒态：显示半透明边框 + 标题栏 + 工具栏 + 右下角缩放手柄，可拖拽/缩放。
# 唤醒后 5 秒无操作 → 自动回到无痕态。位置/大小/字体经 SettingsManager 持久化。
class_name HintPanel
extends Control

const MIN_SIZE := Vector2(240, 140)
const TITLE_H := 36
const RESIZE_MARGIN := 18
const MIN_FONT := 12
const MAX_FONT := 32
const GHOST_AFTER_MS := 5000
## 无痕态顶部唤醒热区的高度（无痕态文字区点击穿透，这块窄条保留「点一下唤醒」的入口）。
const GHOST_GRIP_H := 8

var _panel: PanelContainer
var _content: RichTextLabel
var _font_size: int = 16
var _font_label: Label
var _btn_close: Button
var _btn_dec: Button
var _btn_inc: Button
var _ghost_grip: Control
var _title_bar: Control
var _sep1: HSeparator
var _sep2: HSeparator
var _toolbar: HBoxContainer
var _resize_handle: Control
var _dragging := false
var _drag_start := Vector2.ZERO
var _resizing := false
var _resize_start_mouse := Vector2.ZERO
var _resize_start_size := Vector2.ZERO
var _ghost := true
var _ghost_deadline_ms := 0


func _ready() -> void:
	add_to_group("themed")
	_font_size = clampi(SettingsManager.hint_font_size, MIN_FONT, MAX_FONT)
	_build()
	_apply_theme()
	ThemeManager.theme_changed.connect(_apply_theme)
	# 恢复窗口几何（尺寸非法则用默认）
	size = SettingsManager.hint_window_size
	if size.x < MIN_SIZE.x or size.y < MIN_SIZE.y:
		size = MIN_SIZE
	position = SettingsManager.hint_window_pos
	_clamp_to_viewport()
	visible = false  # 首次有提示前隐藏
	set_process(true)


func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	_panel.add_child(v)

	# 标题栏（拖拽手柄，无痕态隐藏）
	# 无痕态唤醒热区（2026-09-25）：无痕态下文字区改为**点击穿透**（否则浮窗压在盘上时
	# 那块区域点不动，且因点不动就触发不了「盘面变化清除浮窗」，形成自锁死区——审计发现）。
	# 但穿透会失去「点文字唤醒」这条路，所以顶部留一条极窄热区：点它 = 唤醒。
	_ghost_grip = Control.new()
	_ghost_grip.custom_minimum_size = Vector2(0, GHOST_GRIP_H)
	_ghost_grip.mouse_filter = Control.MOUSE_FILTER_STOP
	_ghost_grip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_ghost_grip.tooltip_text = "点击唤醒提示窗（可拖动 / 调字体）"
	_ghost_grip.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT and ev.pressed:
			_set_ghost(false))
	v.add_child(_ghost_grip)

	_title_bar = Control.new()
	_title_bar.custom_minimum_size = Vector2(0, TITLE_H)
	_title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_title_bar.gui_input.connect(_on_title_gui_input)
	v.add_child(_title_bar)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_bar.add_child(row)
	var tl := Label.new()
	tl.text = "提示"
	tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tl.add_theme_font_size_override("font_size", 16)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(tl)
	_btn_close = Button.new()
	_btn_close.text = "×"
	_btn_close.focus_mode = Control.FOCUS_NONE
	_btn_close.pressed.connect(func(): visible = false)
	row.add_child(_btn_close)

	_sep1 = HSeparator.new()
	v.add_child(_sep1)

	# 内容（自动换行 + 可选中复制；点击文字唤醒调整功能）
	_content = RichTextLabel.new()
	_content.bbcode_enabled = true
	_content.fit_content = false
	_content.selection_enabled = true
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_theme_font_size_override("normal_font_size", _font_size)
	_content.add_theme_constant_override("line_separation", 4)
	_content.mouse_filter = Control.MOUSE_FILTER_STOP
	_content.gui_input.connect(_on_content_gui_input)
	v.add_child(_content)

	_sep2 = HSeparator.new()
	v.add_child(_sep2)

	# 底部工具栏（字体调节，无痕态隐藏）
	_toolbar = HBoxContainer.new()
	_toolbar.add_theme_constant_override("separation", 8)
	_toolbar.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(_toolbar)
	_btn_dec = Button.new()
	_btn_dec.text = "A−"
	_btn_dec.focus_mode = Control.FOCUS_NONE
	_btn_dec.pressed.connect(func(): _adjust_font(-2))
	_toolbar.add_child(_btn_dec)
	_font_label = Label.new()
	_font_label.text = str(_font_size)
	_font_label.add_theme_font_size_override("font_size", 14)
	_toolbar.add_child(_font_label)
	_btn_inc = Button.new()
	_btn_inc.text = "A+"
	_btn_inc.focus_mode = Control.FOCUS_NONE
	_btn_inc.pressed.connect(func(): _adjust_font(2))
	_toolbar.add_child(_btn_inc)

	# 右下角缩放手柄（无痕态隐藏）
	_resize_handle = Control.new()
	_resize_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	_resize_handle.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	_resize_handle.gui_input.connect(_on_resize_gui_input)
	_resize_handle.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_resize_handle.offset_left = -RESIZE_MARGIN
	_resize_handle.offset_top = -RESIZE_MARGIN
	_resize_handle.offset_right = 0
	_resize_handle.offset_bottom = 0
	add_child(_resize_handle)

	_set_ghost(true)


## 显示推理结果：空 → 详细引导说明；非空 → 逐条「■ 雷/安全 (行,列) 推理说明」。
func show_hint(steps: Array) -> void:
	visible = true
	if steps.is_empty():
		_content.text = _empty_hint_text()
	else:
		var mine_hex := _hex(ThemeManager.danger_text())   # 文字场景用提亮版（WCAG AA 对比）
		var safe_hex := _hex(ThemeManager.safe())
		var parts: Array[String] = []
		parts.append("[b]当前可 100% 确定的推理[/b]")
		for s in steps:
			var step := s as ReasoningStep
			if step == null:
				continue
			var is_mine: bool = step.state == "mine"
			var tag := "雷" if is_mine else "安全"
			var hexc := mine_hex if is_mine else safe_hex
			# 坐标转 1-based「行,列」，贴合玩家视角
			parts.append("[color=%s]■ %s[/color] (%d,%d)  %s" % [hexc, tag, step.pos.y + 1, step.pos.x + 1, step.proof])
		_content.text = "\n".join(parts)
	_set_ghost(true)  # 每次新提示从无痕态开始，点击文字再唤醒调整
	_fit_ghost_size()


## 盘面变化 → 旧推理失效：清空内容并隐藏。
func clear_hint() -> void:
	_content.text = ""
	visible = false
	_set_ghost(true)


## 无痕态：窗口尺寸贴合文字内容（贴纸式浮层）；唤醒态保持用户调整的尺寸。
func _fit_ghost_size() -> void:
	if _content == null:
		return
	var vp := get_viewport_rect().size
	var w := clampf(320.0, 200.0, vp.x * 0.7)
	size.x = w  # 先定宽度，让 RichTextLabel 按此宽度换行
	await get_tree().process_frame
	if not _ghost or _content == null or not visible:
		return
	var h := _content.get_content_height()
	if h <= 0.0:
		return
	size = Vector2(w, clampf(h, 24.0, vp.y * 0.85))
	_clamp_to_viewport()


## 无必然一步时的详细引导（逻辑顺序：结论 → 原因 → 观察顺序 → 兜底策略 → 保证）。
func _empty_hint_text() -> String:
	return """[b]当前没有 100% 必然可推的一步[/b]

这表示仅凭当前已翻开的线索，还不足以直接锁定某个格子的雷或安全，属于正常局面。

建议按以下顺序观察：
1. 找「数字恰好等于未翻开邻格数」的格子——它的所有未翻开邻格必为雷。
2. 找「数字为 0」的格子——它周围全部安全，可直接放心翻开。
3. 优先看边缘、角落的数字格，它们邻格更少、约束更强，更容易锁定。
4. 若仍无必然一步，可先翻开一个把握较大的格子，再重新请求提示。

提示只给出 100% 必然成立的结论，绝不猜测。"""


func _adjust_font(delta: int) -> void:
	_font_size = clampi(_font_size + delta, MIN_FONT, MAX_FONT)
	_content.add_theme_font_size_override("normal_font_size", _font_size)
	_font_label.text = str(_font_size)
	SettingsManager.set_hint_font_size(_font_size)


## 点击提示文字 → 唤醒窗口（显示边框 + 调整大小功能）。
func _on_content_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_set_ghost(false)


func _on_title_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_dragging = true
		_drag_start = get_global_mouse_position() - global_position


func _on_resize_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_resizing = true
		_resize_start_mouse = get_global_mouse_position()
		_resize_start_size = size


## 切换无痕/唤醒态：无痕隐藏全部 chrome + 关闭滚动；唤醒显示 chrome + 开启滚动。
func _set_ghost(g: bool) -> void:
	_ghost = g
	if g:
		_ghost_deadline_ms = 0
	else:
		_ghost_deadline_ms = Time.get_ticks_msec() + GHOST_AFTER_MS
	for n in [_title_bar, _sep1, _sep2, _toolbar, _resize_handle]:
		if n != null:
			n.visible = not g
	if _content != null:
		_content.scroll_active = not g
		# 无痕态：文字区**穿透**（点击落到棋盘上）；唤醒态：恢复接收（可选中/复制文本）。
		# 上一行热区负责无痕态的唤醒入口（见 _build 里 _ghost_grip 的注释）。
		_content.mouse_filter = Control.MOUSE_FILTER_IGNORE if g else Control.MOUSE_FILTER_STOP
	if _ghost_grip != null:
		_ghost_grip.visible = g
	_apply_theme()


func _process(_delta: float) -> void:
	var changed := false
	if _dragging:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			global_position = get_global_mouse_position() - _drag_start
			_clamp_to_viewport()
		else:
			_dragging = false
			changed = true
	if _resizing:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			var d := get_global_mouse_position() - _resize_start_mouse
			size = (_resize_start_size + d).max(MIN_SIZE)
		else:
			_resizing = false
			changed = true
	# 拖拽/缩放交互中持续刷新 5 秒计时，避免调整中途被切回无痕
	if _dragging or _resizing:
		if not _ghost:
			_ghost_deadline_ms = Time.get_ticks_msec() + GHOST_AFTER_MS
	elif not _ghost and _ghost_deadline_ms > 0 and Time.get_ticks_msec() > _ghost_deadline_ms:
		_set_ghost(true)
	if changed:
		_save_geometry()


func _save_geometry() -> void:
	SettingsManager.set_hint_window_pos(position)
	SettingsManager.set_hint_window_size(size)


func _clamp_to_viewport() -> void:
	var vp := get_viewport_rect().size
	global_position.x = clampf(global_position.x, 0.0, maxf(0.0, vp.x - size.x))
	global_position.y = clampf(global_position.y, 0.0, maxf(0.0, vp.y - size.y))


func _apply_theme() -> void:
	if _panel == null:
		return
	if _ghost:
		# 无痕态：完全透明，无边框、无背景、无阴影
		_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	else:
		# 唤醒态：透明底色 + 细边框（可辨识窗口，仍保持透明）
		var sb := StyleBoxFlat.new()
		var base := ThemeManager.card()
		sb.bg_color = Color(base.r, base.g, base.b, 0.18)
		sb.set_corner_radius_all(10)
		sb.set_border_width_all(1)
		sb.border_color = ThemeManager.grid_line()
		_panel.add_theme_stylebox_override("panel", sb)
	if _content != null:
		_content.add_theme_color_override("default_color", ThemeManager.text())
	for b in [_btn_close, _btn_dec, _btn_inc]:
		if b != null:
			UiTheme.style_button(b)


func _hex(c: Color) -> String:
	return "#%02x%02x%02x" % [int(c.r * 255), int(c.g * 255), int(c.b * 255)]
