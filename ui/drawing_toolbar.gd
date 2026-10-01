# drawing_toolbar.gd —— 底栏绘画工具栏（绘画开关 / 色带 / 粗细 / 橡皮 / 擦除模式 / 清空）
# 位于棋盘与绘画层之上，鼠标事件优先于绘画层，保证绘画模式下仍可点击工具栏。
# 缩进：全仓库统一 1 Tab（见交接文档 08 编码规范）。
extends Control

## 图标工厂（工程纪律：ui_icons 无 class_name，调用方一律 preload，见坑表 #26）。
const Icons := preload("res://ui/ui_icons.gd")

var _drawing: DrawingLayer

var _paint_btn: Button
var _erase_btn: Button
var _erase_mode_btn: Button
var _clear_btn: Button
var _swatches: Array = []
var _size_btns: Array = []
var _tools_box: VBoxContainer
## 工具面板的**底板**（2026-09-29 新增）。原先 _tools_box 是个裸 VBoxContainer，
## 色带 / 粗细 / 橡皮直接浮在棋盘上 —— 与棋盘格颜色一接近就糊成一团，也看不出
## "这是一个面板"。包一层带卡片底 + 描边 + 软阴影的 PanelContainer 才像个物件。
var _tools_panel: PanelContainer
## 毛笔图标缓存（key = 文字色|强调色）：ThemeManager 一次切换广播多次 theme_changed，
## 不缓存则每次广播都重新 SVG 光栅化
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

	# 「绘画」按钮：并入 HUD 顶栏右上角那一排图标（对齐 CozySudoku 顶栏右侧单排图标的做法），
	# 占 col 2（col0 = 设置、col1 = 换肤，由 ui/hud.gd 放置）；点击展开/收起工具面板（同时切绘画模式）。
	#
	# ⚠️ 2026-09-29 之前它悬在 (right-68..right-20, y=150..198) —— 上下都不挨着任何东西，
	#    是用户点名的"布局很丑"之一。2026-09-29 与 hud.gd 共用同一组常量（TOOLBAR_EDGE=24 /
	#    TOOLBAR_GAP=8 / ICON_BTN_SIZE=40），row 1 = 顶栏正下方；2026-09-30 再并到 **row 0**，
	#    与设置/换肤同排（原先它在 row 1，右上角成了两行）。两个场景各有一份常量、
	#    靠注释互相指着 —— hud.gd 那边改了必须同步这里。
	_paint_btn = Button.new()
	_paint_btn.text = ""
	_paint_btn.icon = _brush_icon()
	_paint_btn.expand_icon = true
	_paint_btn.tooltip_text = "绘画"
	_paint_btn.toggle_mode = true
	_paint_btn.focus_mode = Control.FOCUS_NONE
	_paint_btn.custom_minimum_size = Vector2(40, 40)
	_paint_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_paint_btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_paint_btn.grow_vertical = Control.GROW_DIRECTION_END
	_paint_btn.offset_left = -(24.0 + 2.0 * (40.0 + 8.0) + 40.0)
	_paint_btn.offset_right = -(24.0 + 2.0 * (40.0 + 8.0))
	_paint_btn.offset_top = 12.0
	_paint_btn.offset_bottom = 12.0 + 40.0
	_paint_btn.toggled.connect(func(on: bool):
		if _drawing != null:
			_drawing.set_paint_mode(on)
		if _tools_panel != null:
			_tools_panel.visible = on)
	add_child(_paint_btn)

	# 绘画工具面板：带底板，在「绘画」按钮正下方展开（图标行 row0 下方 = row1 的位置）
	_tools_panel = PanelContainer.new()
	_tools_panel.visible = false
	_tools_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_tools_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_tools_panel.grow_vertical = Control.GROW_DIRECTION_END
	_tools_panel.offset_left = -232.0
	_tools_panel.offset_right = -24.0
	_tools_panel.offset_top = 12.0 + (40.0 + 8.0)
	_tools_panel.offset_bottom = 12.0 + (40.0 + 8.0) + 262.0
	add_child(_tools_panel)

	_tools_box = VBoxContainer.new()
	_tools_box.add_theme_constant_override("separation", 8)
	_tools_panel.add_child(_tools_box)

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

	# 【2026-09-30 图标化】文本 → 图标（白模 SVG 由按钮 icon 色乘色）；语义移到 tooltip
	#（test_drawing_toolbar 的 _find_button 同时匹配 text/tooltip，锚点不丢）。
	_erase_btn = Button.new()
	_erase_btn.icon = Icons.eraser()
	_erase_btn.expand_icon = true
	_erase_btn.custom_minimum_size = Vector2(0, 40)
	_erase_btn.tooltip_text = "橡皮"
	_erase_btn.toggle_mode = true
	_erase_btn.focus_mode = Control.FOCUS_NONE
	_erase_btn.toggled.connect(func(on: bool):
		if _drawing != null:
			_drawing.is_erasing = on
			_drawing.changed.emit())
	_tools_box.add_child(_erase_btn)

	# 擦除模式：整条（命中即删整笔）/ 局部（只擦覆盖到的片段）
	_erase_mode_btn = Button.new()
	_erase_mode_btn.icon = Icons.eraser()
	_erase_mode_btn.expand_icon = true
	_erase_mode_btn.custom_minimum_size = Vector2(0, 40)
	_erase_mode_btn.tooltip_text = "擦整条"
	_erase_mode_btn.toggle_mode = true
	_erase_mode_btn.focus_mode = Control.FOCUS_NONE
	_erase_mode_btn.toggled.connect(func(on: bool):
		if _drawing != null:
			_drawing.erase_mode = (
					DrawingLayer.EraseMode.PARTIAL if on else DrawingLayer.EraseMode.WHOLE)
			_drawing.changed.emit())
	_tools_box.add_child(_erase_mode_btn)

	_clear_btn = Button.new()
	_clear_btn.icon = Icons.trash()
	_clear_btn.expand_icon = true
	_clear_btn.custom_minimum_size = Vector2(0, 40)
	_clear_btn.tooltip_text = "清空绘画"
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
	if _tools_panel != null:
		_tools_panel.visible = _drawing.paint_mode
	_erase_btn.set_pressed_no_signal(_drawing.is_erasing)
	var partial: bool = _drawing.erase_mode == DrawingLayer.EraseMode.PARTIAL
	_erase_mode_btn.set_pressed_no_signal(partial)
	# 【2026-09-30 图标化】文案 → 图标（局部 = 带渐隐点的橡皮）+ 短词 tooltip
	#（test_drawing_toolbar 的 _find_button 靠 text/tooltip 精确匹配）。
	_erase_mode_btn.icon = Icons.eraser_partial() if partial else Icons.eraser()
	_erase_mode_btn.tooltip_text = "擦局部" if partial else "擦整条"
	for i in _swatches.size():
		_style_swatch(_swatches[i], i)
	for i in _size_btns.size():
		_style_size_btn(_size_btns[i], i)


func _style_swatch(sw: Button, i: int) -> void:
	UiTheme.style_swatch(sw, _drawing.color_of(i), _drawing.current_color == i)


func _style_size_btn(b: Button, i: int) -> void:
	var active: bool = _drawing.current_size == i
	var base_bg: Color = ThemeManager.accent() if active else ThemeManager.card()
	var sb := StyleBoxFlat.new()
	sb.bg_color = base_bg
	sb.set_corner_radius_all(6)
	# 【2026-10-01 抖动修复 ④】normal / hover / pressed 共用这一份（原实现 hover 换整份
	# stylebox、还连带把字色也换掉 —— 换样式是瞬时的，与 0.2s 缩放不同步 ⇒ 抖动；
	# 根因说明见 UiTheme.META_STATE_COLORS）。现悬停只把底色提亮一档：色相不变 ⇒
	# 字色无需跟着换，零瞬变。
	for state in ["normal", "hover", "pressed"]:
		b.add_theme_stylebox_override(state, sb)
	UiTheme.bind_state_colors(b, {
		"bg": [base_bg, base_bg.lightened(0.08), base_bg.darkened(0.10)],
	})
	# 选中态的底是**实心 accent**，字色必须是配套的 accent_text；
	# 未选中态底是 card，才用 text。原先两种状态共用 text()，
	# 在浅色系主题下（accent #2D7BB0 vs text #232323 ≈ 1.9:1）会糊成一片。
	var font := ThemeManager.accent_text() if active else ThemeManager.text()
	b.add_theme_color_override("font_color", font)
	b.add_theme_color_override("font_hover_color", font)
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
	if _tools_panel != null:
		_style_tools_panel()
	if _drawing != null:
		refresh()
	queue_redraw()


## 工具面板底板：卡片底 + 描边 + 常态软阴影（与按钮同一套阴影口径，见 UiTheme）。
func _style_tools_panel() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = ThemeManager.card()
	sb.set_corner_radius_all(12)
	sb.corner_detail = 14
	sb.anti_aliasing = true
	sb.set_border_width_all(1)
	sb.border_color = ThemeManager.grid_line()
	sb.shadow_color = ThemeManager.shadow(ThemeManager.bg())
	sb.shadow_size = UiTheme.NORMAL_SHADOW_SIZE
	sb.shadow_offset = UiTheme.NORMAL_SHADOW_OFFSET
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	_tools_panel.add_theme_stylebox_override("panel", sb)


func _style_button(btn: Button) -> void:
	# 图标按钮（只有 icon、没有 text，配 expand_icon）必须走**对称内边距**那套：
	# 文字按钮的 16/8 会把 48×48 的「绘画」按钮的内容区压成 16×16，毛笔图标随之被
	# 缩成一小块（2026-09-29 实测；同款问题见 UiTheme.ICON_PAD 的说明）。
	if btn.text == "" and btn.icon != null:
		UiTheme.style_icon_button(btn)
	else:
		UiTheme.style_button(btn)


func _on_theme_changed() -> void:
	_apply_theme()
