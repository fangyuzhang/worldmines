# tutorial_overlay.gd —— 教程覆盖层（对标游戏 doc10 §1.4）
#
# 对标实现是一个 Autoload 单例 `TutorialOverlay`（含 DemoGrid + RichTextLabel + 按钮数组），
# 本实现改为「可实例化的 Control」：由调用方 add_child + open(pages)，避免污染 autoload 列表。
#
# 能力：
#   · 按 `Tutorial.parse` 的盘面数据绘制 Demo 盘（沿用文档的注解语义：强调/线索/悬停/错误）
#   · 右侧显示提示正文
#   · 上一步 / 下一步 / 关闭
#
# 注意：**不要给本文件加 class_name** —— headless 下新全局类不在 .godot 缓存里会解析失败
#（坑表 #26）。调用方用 preload 引用。
extends Control

const TutorialData := preload("res://core/tutorial.gd")


## 盘面绘制：按页数据画格子 + 注解标记。
## 抽成内部类是为了让 _draw 只关心画画，教程页切换只改 page 字段。
class DemoGrid extends Control:
	var page: Dictionary = {}

	func set_page(p: Dictionary) -> void:
		page = p
		queue_redraw()

	func _draw() -> void:
		var rows: Array = page.get("rows", [])
		if rows.is_empty():
			return
		var cols: int = int(page.get("cols", 0))
		if cols <= 0:
			return
		var font := get_theme_default_font()
		var fsize := 18
		var pad := 12.0
		var avail := size - Vector2(pad * 2, pad * 2)
		var cell := minf(avail.x / float(cols), avail.y / float(maxi(rows.size(), 1)))
		if cell <= 2.0:
			return
		var origin := Vector2(pad, pad)
		for r in rows.size():
			var row: Array = rows[r]
			for c in row.size():
				var cd: Dictionary = row[c]
				var value := str(cd.get("value", ""))
				var ann: Array = cd.get("annotations", [])
				if value == "" and ann.is_empty():
					continue  # 空单元格 = 视觉留白（分组分隔）
				var rect := Rect2(origin + Vector2(c, r) * cell, Vector2(cell, cell))
				var inner := rect.grow(-1.0)
				draw_rect(inner, Color(ThemeManager.text(), 0.10), true)
				var border := ThemeManager.accent()
				border.a = 0.7
				var width := 1.0
				if TutorialData.is_clue(ann):
					width = 2.0
				if TutorialData.is_emphasis(ann):
					draw_rect(inner, Color(ThemeManager.accent(), 0.22), true)
					width = 3.0
				draw_rect(inner, border, false, width)
				if TutorialData.is_hover(ann):
					var hs := Color(ThemeManager.accent(), 0.9)
					var inset := rect.grow(-3.0)
					draw_dashed_line(inset.position, Vector2(inset.end.x, inset.position.y), hs, 1.0)
					draw_dashed_line(Vector2(inset.position.x, inset.end.y), inset.end, hs, 1.0)
				if value != "" and font != null:
					var tw := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize)
					draw_string(font, rect.position + Vector2((cell - tw.x) * 0.5, (cell + tw.y * 0.6) * 0.5),
						value, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, ThemeManager.text())
				if TutorialData.is_wrong(ann):
					var e := rect.grow(-4.0)
					var col := ThemeManager.danger()
					draw_line(e.position, e.end, col, 3.0)
					draw_line(Vector2(e.end.x, e.position.y), Vector2(e.position.x, e.end.y), col, 3.0)


var _pages: Array[String] = []
var _index := 0
var _grid: DemoGrid = null
var _title: Label = null
var _text: RichTextLabel = null
var _prev_btn: Button = null
var _next_btn: Button = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()


func _build_ui() -> void:
	# 遮罩背景（拦截下层输入）
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 32)
	margin.add_theme_constant_override("margin_bottom", 32)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 24)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_title)

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 20)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(split)

	_grid = DemoGrid.new()
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid.custom_minimum_size = Vector2(360, 300)
	split.add_child(_grid)

	_text = RichTextLabel.new()
	_text.bbcode_enabled = false
	_text.fit_content = false
	_text.custom_minimum_size = Vector2(320, 0)
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text.add_theme_font_size_override("normal_font_size", 16)
	split.add_child(_text)

	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	vbox.add_child(bar)

	_prev_btn = Button.new()
	_prev_btn.text = "上一步"
	_prev_btn.focus_mode = Control.FOCUS_NONE
	_prev_btn.pressed.connect(func(): _go(-1))
	bar.add_child(_prev_btn)

	_next_btn = Button.new()
	_next_btn.text = "下一步"
	_next_btn.focus_mode = Control.FOCUS_NONE
	_next_btn.pressed.connect(func(): _go(1))
	bar.add_child(_next_btn)

	var close := Button.new()
	close.text = "关闭"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(close_overlay)
	bar.add_child(close)


## 打开教程。pages 为空时列出全部教程页。
func open(pages: Array = []) -> void:
	if _pages.is_empty():
		if pages.is_empty():
			pages = TutorialData.list_ids()
		for p in pages:
			_pages.append(str(p))
	_index = 0
	_refresh()


func close_overlay() -> void:
	queue_free()


func _go(delta: int) -> void:
	if _pages.is_empty():
		return
	_index = clampi(_index + delta, 0, _pages.size() - 1)
	_refresh()


func _refresh() -> void:
	if _pages.is_empty():
		_title.text = "教程"
		_text.text = "暂无教程内容。\n\n在 res://levels/tutorial/ 下放置 tutorial_<规则组合>_<序号>.txt 即可。"
		if _grid != null:
			_grid.set_page({})
		return
	var id: String = _pages[_index]
	var page := TutorialData.load_page(id)
	if str(page.get("error", "")) != "":
		_title.text = id
		_text.text = "该教程页解析失败：\n%s" % str(page["error"])
		return
	_title.text = "%s（%d/%d）" % [id, _index + 1, _pages.size()]
	if _grid != null:
		_grid.set_page(page)
	if _text != null:
		_text.text = str(page.get("text", ""))
	if _prev_btn != null:
		_prev_btn.disabled = _index <= 0
	if _next_btn != null:
		_next_btn.disabled = _index >= _pages.size() - 1


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed:
		var k := (event as InputEventKey).keycode
		if k == KEY_ESCAPE:
			close_overlay()
		elif k == KEY_LEFT:
			_go(-1)
		elif k == KEY_RIGHT:
			_go(1)
