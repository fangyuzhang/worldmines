# drawing_toolbar.gd —— 底栏绘画工具栏（绘画开关 / 色带 / 粗细 / 橡皮 / 擦除模式 / 清空）
# 位于棋盘与绘画层之上，鼠标事件优先于绘画层，保证绘画模式下仍可点击工具栏。
# 缩进：全仓库统一 1 Tab（见交接文档 08 编码规范）。
extends Control

var _drawing: DrawingLayer

var _paint_btn: Button
var _erase_btn: Button
var _erase_mode_btn: Button
var _clear_btn: Button
var _swatches: Array = []
var _size_btns: Array = []
var _tools_box: VBoxContainer
# 毛笔图标缓存（key = 文字色|强调色）：ThemeManager 一次切换广播多次 theme_changed，
# 不缓存则每次广播都重新 SVG 光栅化
var _icon_cache := {}


func setup(layer: DrawingLayer) -> void:
	_drawing = layer
	if not layer.changed.is_connected(refresh):
		layer.changed.connect(refresh)
	refresh()


func _ready() -> void:
	add_to_group("themed")
	ThemeManager.theme_changed.connect(_on_theme_changed)
	_build_ui()


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # 全屏但不拦截鼠标，仅按钮可点

	# 「绘画」按钮：固定在界面右侧，毛笔图标，点击展开/收起工具面板（同时切换绘画模式）
	_paint_btn = Button.new()
	_paint_btn.text = ""
	_paint_btn.icon = _brush_icon()
	_paint_btn.expand_icon = true
	_paint_btn.tooltip_text = "绘画"
	_paint_btn.toggle_mode = true
	_paint_btn.focus_mode = Control.FOCUS_NONE
	_paint_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_paint_btn.offset_left = -68
	_paint_btn.offset_right = -20
	_paint_btn.offset_top = 150
	_paint_btn.offset_bottom = 198
	_paint_btn.toggled.connect(func(on: bool):
		if _drawing != null:
			_drawing.set_paint_mode(on)
		if _tools_box != null:
			_tools_box.visible = on)
	add_child(_paint_btn)

	# 绘画工具面板：竖向排列，在「绘画」按钮下方展开
	_tools_box = VBoxContainer.new()
	_tools_box.visible = false
	_tools_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_tools_box.offset_left = -240
	_tools_box.offset_right = -20
	_tools_box.offset_top = 200
	_tools_box.offset_bottom = 470
	_tools_box.add_theme_constant_override("separation", 8)
	add_child(_tools_box)

	# 色带（7 色：横排一行）
	var color_row := HBoxContainer.new()
	color_row.add_theme_constant_override("separation", 6)
	_tools_box.add_child(color_row)
	for i in DrawingLayer.COLOR_COUNT:
		var sw := Button.new()
		sw.custom_minimum_size = Vector2(24, 24)
		sw.focus_mode = Control.FOCUS_NONE
		sw.tooltip_text = "颜色 %d" % (i + 1)
		sw.pressed.connect(_on_swatch_pressed.bind(i))
		_swatches.append(sw)
		color_row.add_child(sw)

	_tools_box.add_child(_hsep())

	# 粗细 细/中/粗（横排一行）
	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 6)
	_tools_box.add_child(size_row)
	for i in DrawingLayer.SIZES.size():
		var b := Button.new()
		b.text = ["细", "中", "粗"][i]
		b.custom_minimum_size = Vector2(52, 30)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_on_size_pressed.bind(i))
		_size_btns.append(b)
		size_row.add_child(b)

	_tools_box.add_child(_hsep())

	_erase_btn = Button.new()
	_erase_btn.text = "橡皮"
	_erase_btn.toggle_mode = true
	_erase_btn.focus_mode = Control.FOCUS_NONE
	_erase_btn.toggled.connect(func(on: bool):
		if _drawing != null:
			_drawing.is_erasing = on
			_drawing.changed.emit())
	_tools_box.add_child(_erase_btn)

	# 擦除模式：整条（命中即删整笔）/ 局部（只擦覆盖到的片段）
	_erase_mode_btn = Button.new()
	_erase_mode_btn.toggle_mode = true
	_erase_mode_btn.focus_mode = Control.FOCUS_NONE
	_erase_mode_btn.toggled.connect(func(on: bool):
		if _drawing != null:
			_drawing.erase_mode = (
					DrawingLayer.EraseMode.PARTIAL if on else DrawingLayer.EraseMode.WHOLE)
			_drawing.changed.emit())
	_tools_box.add_child(_erase_mode_btn)

	_clear_btn = Button.new()
	_clear_btn.text = "清空绘画"
	_clear_btn.focus_mode = Control.FOCUS_NONE
	_clear_btn.pressed.connect(_on_clear)
	_tools_box.add_child(_clear_btn)

	_apply_theme()


func _on_swatch_pressed(i: int) -> void:
	if _drawing == null:
		return
	_drawing.set_color(i)


func _on_size_pressed(i: int) -> void:
	if _drawing == null:
		return
	_drawing.set_brush_size(i)


func _on_clear() -> void:
	if _drawing == null:
		return
	if _drawing.strokes.size() > 10:
		UiConfirm.ask(self, "确定清除全部绘画吗？此操作可撤销。", "清除", "取消",
				_drawing.clear_all)
	else:
		_drawing.clear_all()


## 从绘画层同步所有控件状态（颜色选中框 / 大小 / 橡皮 / 擦除模式 / 绘画开关）
func refresh() -> void:
	if _drawing == null:
		return
	_paint_btn.set_pressed_no_signal(_drawing.paint_mode)
	if _tools_box != null:
		_tools_box.visible = _drawing.paint_mode
	_erase_btn.set_pressed_no_signal(_drawing.is_erasing)
	var partial: bool = _drawing.erase_mode == DrawingLayer.EraseMode.PARTIAL
	_erase_mode_btn.set_pressed_no_signal(partial)
	_erase_mode_btn.text = "擦局部" if partial else "擦整条"
	_erase_mode_btn.tooltip_text = (
			"当前：只擦掉笔迹被覆盖的片段" if partial else "当前：命中即删除整条笔记")
	for i in _swatches.size():
		_style_swatch(_swatches[i], i)
	for i in _size_btns.size():
		_style_size_btn(_size_btns[i], i)


func _style_swatch(sw: Button, i: int) -> void:
	UiTheme.style_swatch(sw, _drawing.color_of(i), _drawing.current_color == i)


func _style_size_btn(b: Button, i: int) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = ThemeManager.accent() if _drawing.current_size == i else ThemeManager.card()
	sb.set_corner_radius_all(6)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_color_override("font_color", ThemeManager.text())
	var sbh := sb.duplicate()
	sbh.bg_color = ThemeManager.accent()
	b.add_theme_stylebox_override("hover", sbh)
	UiTheme.bind_hover(b, 1.03)


func _hsep() -> HSeparator:
	var s := HSeparator.new()
	return s


## 毛笔图标（程序化 SVG → ImageTexture）：笔杆 = 文字色，笔头 = 强调色。
## 同色组合命中缓存直接返回（一次主题切换广播 ~10 次 theme_changed，此前每次都重建纹理）。
func _brush_icon() -> ImageTexture:
	var body := _hex(ThemeManager.text())
	var tip := _hex(ThemeManager.accent())
	var key := "%s|%s" % [body, tip]
	if _icon_cache.has(key):
		return _icon_cache[key]
	var svg := """<svg xmlns="http://www.w3.org/2000/svg" width="28" height="28" viewBox="0 0 28 28">
<path d="M5 3 L17 15 L13 20 L1 8 Z" fill="%s"/>
<path d="M17 15 L22 22 L13 20 Z" fill="%s"/>
</svg>""" % [body, tip]
	var img := Image.new()
	if img.load_svg_from_string(svg, 1.0) != OK or img.is_empty():
		return null
	var tex := ImageTexture.create_from_image(img)
	_icon_cache[key] = tex
	return tex


func _hex(c: Color) -> String:
	return "#%02x%02x%02x" % [int(c.r * 255), int(c.g * 255), int(c.b * 255)]


func _apply_theme() -> void:
	for b in [_paint_btn, _erase_btn, _erase_mode_btn, _clear_btn]:
		if b != null:
			_style_button(b)
	if _paint_btn != null:
		_paint_btn.icon = _brush_icon()  # 主题切换时图标颜色随取色更新
	if _drawing != null:
		refresh()
	queue_redraw()


func _style_button(btn: Button) -> void:
	UiTheme.style_button(btn)


func _on_theme_changed() -> void:
	_apply_theme()
