# editor_help.gd —— 编辑器「说明」层（2026-10-02 用户需求，v4）
#
# 沿革：v1 贴按钮（压棋盘）→ v2 中间区 + 模糊 + 页签同步 → v3 去模糊/压紧排版 →
# v4（本轮用户要求）：
#   ① **点说明外任意一处即关闭**（点卡片上不关）；
#   ② **左栏按钮的说明必须都在** —— v3 里"当前页总述 + 页面长文"两张高卡把版面吃光，
#      左栏按钮的卡片被"放不下就不画"的规则挤没了；v4 **不再有"页"级卡片**；
#   ③ **不要解释"属性/验证"这种大类**，只解释**控件**（按钮、填空、下拉、勾选…）。
#
# 不变的约定：
#   · 每帧读目标控件的全局矩形 ⇒ 滚动/布局一变，卡片自己跟过去；
#   · 卡片自带样式（近黑底 + 细白边 + 白字）⇒ 任何主题下都是"白字压深底"；
#   · 放不下的不显示（`fits`），不往屏幕外画；
#   · 说明开着时**画布不可操作**（本层全屏吃掉鼠标 ⇒ 点了就是"点了外面"，于是顺手关闭）。
extends Control

signal dismissed                                   # 点了说明外 / 按 ESC

const CARD_W := 236.0
const GAP_X := 18.0
const GAP_Y := 4.0
const ELBOW := 10.0
const INK := Color(0.97, 0.97, 1.0, 0.85)
const CARD_BG := Color(0.05, 0.06, 0.09, 0.97)
const CARD_BORDER := Color(1, 1, 1, 0.42)
const HEAD_COLOR := Color(1.0, 0.95, 0.78, 1.0)
const TEXT_COLOR := Color(1, 1, 1, 1.0)
## 【审查修 B8】本轮布局里"单张卡片本身就比视口高"而被迫隐藏的张数（0 = 全都显示出来了）。
## 有了它，测试才能钉住"不许静默丢卡片"（原来只有 `card_count()` 数 `_items`，永远绿）。
var _dropped := 0
const SCRIM := Color(0.0, 0.0, 0.0, 0.28)          # 画布轻微压暗（不模糊）

var _items: Array[Dictionary] = []
var _fan := Rect2()
var _scrim: Control = null


## items: [{"btn": Control, "title": String, "text": String, "page": bool}]；
## fan: 画布控件（压暗层与卡片列都以它的矩形为准）。
func setup(items: Array, fan: Control = null) -> void:
	# 【点外面即关】本层全屏吃鼠标 ⇒ 画布上的点击不会落到棋盘（"说明开着不操作其他功能"），
	# 而点子节点（卡片是 STOP）不会冒泡到这里，所以"点卡片不关、点别处关"。
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if fan != null and is_instance_valid(fan):
		_fan = fan.get_global_rect()
	if _fan.size.x < 80.0:
		_fan = Rect2(size.x * 0.3, 0.0, minf(CARD_W + 40.0, size.x * 0.4), size.y)
	var rect := ColorRect.new()
	rect.color = SCRIM
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE        # 只负责压暗，不负责吃事件
	rect.set_meta("scrim", true)
	add_child(rect)
	_scrim = rect
	for it in items:
		var btn: Variant = it.get("btn")
		if btn == null or not is_instance_valid(btn):
			continue
		var card := _make_card(str(it.get("title", "")), str(it.get("text", "")))
		_items.append({"btn": btn, "card": card, "page": bool(it.get("page", false))})


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		dismissed.emit()
		accept_event()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		dismissed.emit()


func _make_card(title: String, text: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_STOP   # 点卡片本身不要关闭说明
	card.add_theme_stylebox_override("panel", _card_style())
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_STOP
	col.add_theme_constant_override("separation", 1)
	card.add_child(col)
	var head := Label.new()
	head.text = "【%s】" % title
	head.add_theme_font_size_override("font_size", 12)
	head.add_theme_color_override("font_color", HEAD_COLOR)
	col.add_child(head)
	var body := Label.new()
	body.text = text
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(CARD_W - 16.0, 0)
	body.add_theme_font_size_override("font_size", 13)          # 用户："看不清根本" ⇒ 正文再大一号
	body.add_theme_color_override("font_color", TEXT_COLOR)   # 纯白（用户："换成白色的字就行"）
	col.add_child(body)
	add_child(card)
	return card


func _card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = CARD_BG
	sb.border_color = CARD_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 5.0
	sb.content_margin_bottom = 5.0
	return sb


## 换页时整组替换"右侧那一页控件的卡片"：不重建整层（重建会让调用方手里的层引用失效）。
func set_page_items(items: Array) -> void:
	var kept: Array[Dictionary] = []
	for it in _items:
		if bool(it.get("page", false)):
			(it["card"] as Node).queue_free()
		else:
			kept.append(it)
	_items = kept
	for it in items:
		var btn: Variant = it.get("btn")
		if btn == null or not is_instance_valid(btn):
			continue
		var card := _make_card(str(it.get("title", "")), str(it.get("text", "")))
		kept.append({"btn": btn, "card": card, "page": true})
	_items = kept
	refresh()


func card_count() -> int:
	var n := 0
	for it in _items:
		if is_instance_valid(it["card"]):
			n += 1
	return n


## 被迫隐藏的卡片数（0 = 全都显示出来了）。审查 B8：测试要能断言"不许静默丢"。
func dropped_count() -> int:
	return _dropped


## 右侧那组卡片上的文字（测试用：换页后应当整体换掉）。
func page_card_texts() -> String:
	var out := ""
	for it in _items:
		if not bool(it.get("page", false)) or not is_instance_valid(it["card"]):
			continue
		var col := (it["card"] as Control).get_child(0) as VBoxContainer
		out += (col.get_child(0) as Label).text + " " + (col.get_child(1) as Label).text + "\n"
	return out


func refresh() -> void:
	var origin := global_position
	var host_h := size.y
	if _scrim != null:
		var fr := _fan
		fr.position -= origin
		(_scrim as Control).position = fr.position
		(_scrim as Control).size = fr.size
	var x := _fan.position.x + (_fan.size.x - CARD_W) * 0.5 - origin.x
	var last_bottom := -1.0e9
	_dropped = 0
	for it in _items:
		var btn: Control = it["btn"]
		var card: Control = it["card"]
		var shown := false
		if is_instance_valid(btn) and btn.is_visible_in_tree():
			shown = _host_rect().intersects(btn.get_global_rect())
		card.visible = shown
		if not shown:
			continue
		var br := btn.get_global_rect()
		br.position -= origin
		var h := maxf(card.get_combined_minimum_size().y, 22.0)
		var y := float(place(Rect2(Vector2(x, br.position.y), br.size), h, last_bottom)["y"])
		# 【审查修 B8（真 bug）】原来 `if not fits(...): card.visible = false` —— **静默丢卡片**：
		# 720p 屏 / 左栏滚到底部那一批控件（正是被搬进「说明」的正文）等于**没有说明**，
		# 而测试只数 `_items`（数的是"有效卡片"不是"可见卡片"）⇒ 永远绿。
		# 现在：夹进视口内继续显示（宁可挨着，也不许看不见）；只有"单张卡片本身就比视口高"才隐藏，
		# 且必须记进 `_dropped`，让测试与用户都能知道。
		var limit := host_h - 2.0 - h
		if limit < 0.0:
			card.visible = false
			_dropped += 1
			continue
		y = minf(y, limit)
		card.position = Vector2(x, y)
		card.size = Vector2(CARD_W, h)
		last_bottom = y + h
	queue_redraw()


## 摆位（纯函数，便于单测）：纵向尽量与目标中心对齐；但不许压住上一张卡片。
static func place(btn_rect: Rect2, card_h: float, last_bottom: float) -> Dictionary:
	var y := btn_rect.position.y + btn_rect.size.y * 0.5 - card_h * 0.5
	y = maxf(y, last_bottom + GAP_Y)
	return {"y": y}


## 卡片是否放得下（纯函数，便于单测）：放不下就不显示。
static func fits(y: float, card_h: float, host_h: float) -> bool:
	return y + card_h <= host_h - 2.0


## 折线拐点（纯函数，便于单测）：目标在左 ⇒ 往右连；目标在右 ⇒ 反过来往左连。
static func elbow_points(target: Rect2, card: Rect2) -> PackedVector2Array:
	var y0 := target.position.y + target.size.y * 0.5
	var y1 := card.position.y + card.size.y * 0.5
	var to_right := target.position.x + target.size.x * 0.5 < card.position.x + card.size.x * 0.5
	var x0 := (target.position.x + target.size.x + 5.0) if to_right else (target.position.x - 5.0)
	var x1 := card.position.x if to_right else (card.position.x + card.size.x)
	var xm := (x1 - ELBOW) if to_right else (x1 + ELBOW)
	if (to_right and xm <= x0) or (not to_right and xm >= x0):
		return PackedVector2Array([Vector2(x0, y0), Vector2(x1, y1)])
	return PackedVector2Array([Vector2(x0, y0), Vector2(xm, y0), Vector2(xm, y1), Vector2(x1, y1)])


func _draw() -> void:
	for it in _items:
		var card: Control = it["card"]
		var btn: Variant = it["btn"]
		if not card.visible or btn == null or not is_instance_valid(btn):
			continue
		var tr := (btn as Control).get_global_rect()
		tr.position -= global_position
		var pts := elbow_points(tr, Rect2(card.position, card.size))
		if pts.size() >= 2:
			draw_polyline(pts, INK, 2.0, true)
			draw_circle(pts[0], 3.0, INK)
			draw_circle(pts[pts.size() - 1], 3.0, INK)


func _process(_dt: float) -> void:
	refresh()


func _host_rect() -> Rect2:
	return Rect2(global_position, size)
