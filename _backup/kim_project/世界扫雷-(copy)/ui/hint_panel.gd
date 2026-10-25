# hint_panel.gd —— 提示浮动窗口（可拖拽 + 可缩放 + 自动换行 + 字体可调）
# 替代原先棋盘下方固定一行文字（易被底栏覆盖 / 长文本出界）。
# 位置、大小、字体大小经 SettingsManager 持久化；拖拽/缩放自动钳制在视口内，不会出界。
class_name HintPanel
extends Control

const MIN_SIZE := Vector2(240, 140)
const TITLE_H := 36
const RESIZE_MARGIN := 18
const MIN_FONT := 12
const MAX_FONT := 32

var _panel: PanelContainer
var _content: RichTextLabel
var _font_size: int = 16
var _font_label: Label
var _btn_close: Button
var _btn_dec: Button
var _btn_inc: Button
var _dragging := false
var _drag_start := Vector2.ZERO
var _resizing := false
var _resize_start_mouse := Vector2.ZERO
var _resize_start_size := Vector2.ZERO


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

	# 标题栏（拖拽手柄）
	var title := Control.new()
	title.custom_minimum_size = Vector2(0, TITLE_H)
	title.mouse_filter = Control.MOUSE_FILTER_STOP
	title.gui_input.connect(_on_title_gui_input)
	v.add_child(title)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_child(row)
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

	v.add_child(HSeparator.new())

	# 内容（自动换行 + 可滚动 + 可选中复制）
	_content = RichTextLabel.new()
	_content.bbcode_enabled = true
	_content.fit_content = false
	_content.scroll_active = true
	_content.selection_enabled = true
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_theme_font_size_override("normal_font_size", _font_size)
	_content.add_theme_constant_override("line_separation", 4)
	v.add_child(_content)

	v.add_child(HSeparator.new())

	# 底部工具栏（字体调节）
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	bar.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(bar)
	_btn_dec = Button.new()
	_btn_dec.text = "A−"
	_btn_dec.focus_mode = Control.FOCUS_NONE
	_btn_dec.pressed.connect(func(): _adjust_font(-2))
	bar.add_child(_btn_dec)
	_font_label = Label.new()
	_font_label.text = str(_font_size)
	_font_label.add_theme_font_size_override("font_size", 14)
	bar.add_child(_font_label)
	_btn_inc = Button.new()
	_btn_inc.text = "A+"
	_btn_inc.focus_mode = Control.FOCUS_NONE
	_btn_inc.pressed.connect(func(): _adjust_font(2))
	bar.add_child(_btn_inc)

	# 右下角缩放手柄（↘ 光标提示）
	var handle := Control.new()
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	handle.gui_input.connect(_on_resize_gui_input)
	handle.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	handle.offset_left = -RESIZE_MARGIN
	handle.offset_top = -RESIZE_MARGIN
	handle.offset_right = 0
	handle.offset_bottom = 0
	add_child(handle)


## 显示推理结果：空 → 提示语；非空 → 逐条「■ 雷/安全 (行,列) 说明」。
func show_hint(steps: Array) -> void:
	visible = true
	if steps.is_empty():
		_content.text = "[color=gray]暂无必然可推的一步：先多翻开几格[/color]"
		return
	var mine_hex := _hex(ThemeManager.danger())
	var safe_hex := _hex(ThemeManager.safe())
	var parts: Array[String] = []
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


## 盘面变化 → 旧推理失效：清空内容并隐藏。
func clear_hint() -> void:
	_content.text = ""
	visible = false


func _adjust_font(delta: int) -> void:
	_font_size = clampi(_font_size + delta, MIN_FONT, MAX_FONT)
	_content.add_theme_font_size_override("normal_font_size", _font_size)
	_font_label.text = str(_font_size)
	SettingsManager.set_hint_font_size(_font_size)


func _on_title_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_dragging = true
		_drag_start = get_global_mouse_position() - global_position


func _on_resize_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_resizing = true
		_resize_start_mouse = get_global_mouse_position()
		_resize_start_size = size


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
	var sb := StyleBoxFlat.new()
	sb.bg_color = ThemeManager.card()
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(1)
	sb.border_color = ThemeManager.grid_line()
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 16
	sb.shadow_offset = Vector2(0, 4)
	_panel.add_theme_stylebox_override("panel", sb)
	if _content != null:
		_content.add_theme_color_override("default_color", ThemeManager.text())
	for b in [_btn_close, _btn_dec, _btn_inc]:
		if b != null:
			UiTheme.style_button(b)


func _hex(c: Color) -> String:
	return "#%02x%02x%02x" % [int(c.r * 255), int(c.g * 255), int(c.b * 255)]
