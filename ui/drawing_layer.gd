# drawing_layer.gd —— 绘画覆盖层（永久保留核心辅助功能，模仿《14 种扫雷变体 2》）
# 纯视觉层：不参与判负/线索/胜利/提示等任何游戏逻辑（红线 2）。
# 坐标 = **棋盘坐标**（不是屏幕坐标）：由 board_view 注入一对换算函数。
#   历史 bug：笔迹原先直接存屏幕坐标，改一次窗口大小（cell_px / board_origin 随之重算）
#   笔记就和格子全部错位，换分辨率读档同理。改棋存盘后 Series 缩放天然跟随棋盘。
#   未注入换算函数时退化为「屏幕坐标 == 棋盘坐标」（保持既有行为，也便于单测独立实例化）。
# 事件拦截：绘画模式 ON → MOUSE_FILTER_STOP（拦鼠标）；OFF → IGNORE（仅显示）。
# 数据独立存储：SaveData.metadata["drawing"]，恢复时一并还原；重开清空；撤销独立（红线 3/6）。
class_name DrawingLayer
extends Control

## 颜色预设（索引 1~6；索引 0 = 主题自适应黑/白，绘制时解析为具体色，主题切换不回变）
const PALETTE: Array[Color] = [
	Color("#E53935"),  # 红 危险/可疑
	Color("#1E88E5"),  # 蓝 安全/已确认
	Color("#43A047"),  # 绿 通过
	Color("#FDD835"),  # 黄 待确认
	Color("#8E24AA"),  # 紫 特殊
	Color("#FB8C00"),  # 橙 中间态
]

## 画笔线宽（细/中/粗）
const SIZES: Array[int] = [2, 4, 6]

const COLOR_COUNT := 7      # 0(主题) + 6 预设
const UNDO_LIMIT := 50

## 存档格式版本。
##   v1（无 v 字段）= 屏幕坐标 —— 棋盘坐标改造后无法对齐；
##   v2 = 棋盘坐标（随棋盘缩放/换分辨率，当前格式）。
## 为什么要显式写版本号：v1 笔迹在新格式下会整体错位，而**错位笔记比没有笔记更危险**
## （玩家会照着错误位置推理）。宁可丢弃旧笔记并明确告知。
const SAVE_VERSION := 2

## 采样节流：与上一个采样点的屏幕距离小于该值则不入笔。
## 鼠标/触控可以以 kHz 频率发 motion 事件，不节流会攒出上万个点，
## 而 _draw() 是逐连线 + 逐点画圆，直接决定每帧开销。
const MIN_SAMPLE_DIST := 2.5

## 棋盘坐标换算钩子（board_view 注入）。空 Callable = 不透换（屏幕坐标即棋盘坐标）。
var board_to_screen := Callable()
var screen_to_board := Callable()

## 本次擦除拖拽的标记 id：替代原先的 _erased_refs 数组（Array.has 是 O(n)，
## 且 strokes 里的笔画不能用 Dictionary 键做成员判断——内容相同的两笔会哈希碰撞）。
var _erase_batch_id := 0
## 擦除时的笔画包围盒缓存（按 strokes 下标），用于快速排除远离光标的笔画。
var _bounds: Array = []

## 非绘画模式（草稿态）的淡化系数：退出绘画后痕迹仍在，但压暗以不干扰读盘
const DIM_FACTOR := 0.55

signal changed

var strokes: Array = []            # 当前笔画 [{points: PackedVector2Array, color: Color, size: int, is_eraser: bool}]
var current_color: int = 0         # 0~6
var current_size: int = 1          # 0=细 1=中 2=粗
var is_erasing: bool = false       # 橡皮模式（E 键切换，影响左键）
var paint_mode: bool = false

## 橡皮擦模式：WHOLE=命中即整条删除；PARTIAL=只擦掉覆盖到的片段，残余留成独立笔画
enum EraseMode { WHOLE, PARTIAL }
var erase_mode: int = EraseMode.WHOLE

# 撤销条目：{"op":"add"|"remove"|"replace"|"batch", ...}
var _undo_stack: Array = []
var _redo_stack: Array = []

enum _Mode { NONE, DRAW, ERASE }
var _mode: int = _Mode.NONE
var _active_stroke: Dictionary = {}
var _erase_batch: Array = []       # 本次擦除累积的撤销条目


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # 默认不拦截
	if SettingsManager != null:
		SettingsManager.settings_changed.connect(_on_settings_changed)
	_refresh_modulate()


# ============ 模式 / 状态 ============

func set_paint_mode(on: bool) -> void:
	# 作画/擦除进行中切出（ESC/P/快捷键）：先按 mouse-release 同款逻辑收尾——
	# 此前直接清 _active_stroke/_erase_batch，该笔/批次已画上却无撤销条目（孤儿，Ctrl+Z 撤不掉）。
	if not on and paint_mode:
		if _mode == _Mode.DRAW:
			_finish_draw()
		elif _mode == _Mode.ERASE:
			_finish_erase()
	paint_mode = on
	mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	_mode = _Mode.NONE
	_active_stroke = {}
	_erase_batch = []
	_refresh_modulate()  # 进入绘画=满不透明（正在作画）；退出=淡化（草稿参考）
	changed.emit()


func is_paint_mode() -> bool:
	return paint_mode


func toggle_paint_mode() -> void:
	set_paint_mode(not paint_mode)


func set_color(i: int) -> void:
	current_color = clampi(i, 0, COLOR_COUNT - 1)
	changed.emit()


func cycle_color(dir: int) -> void:
	current_color = (current_color + dir + COLOR_COUNT) % COLOR_COUNT
	changed.emit()


## 注意：不可命名为 set_size —— Control 已有 set_size(Vector2, bool)，
## 覆写原生方法会被 GDScript 判为 Parse Error（warning treated as error）。
func set_brush_size(i: int) -> void:
	current_size = clampi(i, 0, SIZES.size() - 1)
	changed.emit()


func cycle_size(dir: int) -> void:
	current_size = (current_size + dir + SIZES.size()) % SIZES.size()
	changed.emit()


func toggle_eraser() -> void:
	is_erasing = not is_erasing
	changed.emit()


## 颜色索引 → 实际色（0=主题，绘制时解析，主题切换后既有笔画不回变）
func color_of(i: int) -> Color:
	if i == 0:
		return ThemeManager.text()
	return PALETTE[clampi(i, 1, PALETTE.size()) - 1]


# ============ 输入（仅绘画模式） ============

func _gui_input(event: InputEvent) -> void:
	if not paint_mode:
		return
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cycle_color(-1)
			accept_event()
			return
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cycle_color(1)
			accept_event()
			return
		# 需显式转型：函数参数 event 是 InputEvent，Godot 4.7 在此处不会自动窄化到子类成员
		var mb := event as InputEventMouseButton
		var left: bool = mb.button_index == MOUSE_BUTTON_LEFT
		var right: bool = mb.button_index == MOUSE_BUTTON_RIGHT
		if (left or right) and event.pressed:
			if right or is_erasing:
				_start_erase()
				_erase_at(_to_board(event.position))
			else:
				_start_draw(event.position)
			accept_event()
		elif (left or right) and not event.pressed:
			if _mode == _Mode.DRAW:
				_finish_draw()
			elif _mode == _Mode.ERASE:
				_finish_erase()
			_mode = _Mode.NONE
			accept_event()
	elif event is InputEventMouseMotion:
		if _mode == _Mode.DRAW and not _active_stroke.is_empty():
			var pts: PackedVector2Array = _active_stroke["points"]
			var last: Vector2 = _to_screen(pts[pts.size() - 1])
			# 采样节流：够远才记点（屏幕距离比较，与坐标系换算出耦）
			if (event.position - last).length() >= MIN_SAMPLE_DIST:
				pts.append(_to_board(event.position))
				queue_redraw()
		elif _mode == _Mode.ERASE:
			_erase_at(_to_board(event.position))
		accept_event()


## 屏幕坐标 → 棋盘坐标（未注入换算时透传）。
func _to_board(p: Vector2) -> Vector2:
	return screen_to_board.call(p) if screen_to_board.is_valid() else p


## 棋盘坐标 → 屏幕坐标（未注入换算时透传）。
func _to_screen(p: Vector2) -> Vector2:
	return board_to_screen.call(p) if board_to_screen.is_valid() else p


## 注入棋盘换算（board_view 调用；闭包内部读的是 board_view 的实时字段，布局变化无需重新注入）。
func set_board_transform(b2s: Callable, s2b: Callable) -> void:
	board_to_screen = b2s
	screen_to_board = s2b
	queue_redraw()


func _start_draw(pos: Vector2) -> void:
	_mode = _Mode.DRAW
	_active_stroke = {
		"points": PackedVector2Array([_to_board(pos)]),
		"color": color_of(current_color),
		"size": SIZES[current_size],
		"is_eraser": false,
	}
	strokes.append(_active_stroke)


func _finish_draw() -> void:
	if _active_stroke.is_empty():
		return
	_push_undo({"op": "add", "strokes": [_active_stroke]})
	_redo_stack.clear()
	_active_stroke = {}
	queue_redraw()


func _start_erase() -> void:
	_mode = _Mode.ERASE
	_erase_batch = []
	_erase_batch_id += 1
	_rebuild_bounds()


func _erase_at(pos: Vector2) -> void:
	if erase_mode == EraseMode.WHOLE:
		_erase_whole_at(pos)
	else:
		_erase_partial_at(pos)


## 擦除半径（**棋盘单位**）。有换算时把屏幕上的固定像素半径折算到棋盘空间，
## 保证缩放棋盘后橡皮的视觉大小不变。
func _erase_radius() -> float:
	var r: float = float(SIZES[current_size]) * 2.0
	if screen_to_board.is_valid():
		var zero: Vector2 = screen_to_board.call(Vector2.ZERO)
		var one: Vector2 = screen_to_board.call(Vector2(r, 0.0))
		return maxf((one - zero).x, 0.0001)
	return r


## 是否已处理过该笔画（本次拖拽内）。用笔画字典内的临时字段，O(1)。
func _tagged(s: Dictionary) -> bool:
	return int(s.get("_erase_tag", -1)) == _erase_batch_id


func _tag(s: Dictionary) -> void:
	s["_erase_tag"] = _erase_batch_id


## 重建笔画包围盒（每次拖拽开始时算一次即可，取代原先逐点全扫描）。
func _rebuild_bounds() -> void:
	_bounds.clear()
	for s in strokes:
		var pts: PackedVector2Array = s["points"]
		if pts.is_empty():
			_bounds.append(Rect2())
			continue
		var r := Rect2(pts[0], Vector2.ZERO)
		for p in pts:
			r = r.expand(p as Vector2)
		_bounds.append(r)


## 整条擦除：命中半径即删除整笔（可撤销）
func _erase_whole_at(pos: Vector2) -> void:
	var radius := _erase_radius()
	var removed: Array = []
	# 先用包围盒快速排掉远离光标的笔画（只有命中的候选才逐点判定）
	for i in strokes.size():
		var s: Dictionary = strokes[i]
		if _tagged(s) or (s["points"] as PackedVector2Array).is_empty():
			continue
		var b: Rect2 = _bounds[i] if i < _bounds.size() else Rect2(pos, Vector2.ZERO)
		if not b.grow(radius).has_point(pos):
			continue
		for p in s["points"]:
			if (p as Vector2).distance_to(pos) <= radius:
				_tag(s)
				removed.append(s)
				break
	if removed.is_empty():
		return
	for s in removed:
		strokes.erase(s)
	_erase_batch.append({"op": "remove", "strokes": removed})
	_rebuild_bounds()  # 下标缓存随笔画集合变化失效
	queue_redraw()


## 局部擦除：只擦掉被覆盖的片段，两端残余各自留成独立笔画（可撤销）
func _erase_partial_at(pos: Vector2) -> void:
	var radius := _erase_radius()
	var touched: Array = []
	for s in strokes:
		if _tagged(s):
			continue
		for p in s["points"]:
			if (p as Vector2).distance_to(pos) <= radius:
				_tag(s)
				touched.append(s)
				break
	if touched.is_empty():
		return
	for s in touched:
		var segs := _split_outside(s["points"], pos, radius)
		strokes.erase(s)
		var added: Array = []
		for seg in segs:
			var ns := {
				"points": seg,
				"color": s["color"],
				"size": s["size"],
				"is_eraser": s.get("is_eraser", false),
			}
			strokes.append(ns)
			added.append(ns)
		_erase_batch.append({"op": "replace", "removed": [s], "added": added})
	queue_redraw()


## 把点序列按"是否落在擦除半径内"切成若干段，只保留半径外的段
func _split_outside(pts: PackedVector2Array, center: Vector2, radius: float) -> Array:
	var out: Array = []
	var cur := PackedVector2Array()
	for p in pts:
		if (p as Vector2).distance_to(center) > radius:
			cur.append(p)
		elif cur.size() > 0:
			out.append(cur)
			cur = PackedVector2Array()
	if cur.size() > 0:
		out.append(cur)
	return out


func _finish_erase() -> void:
	if not _erase_batch.is_empty():
		_push_undo({"op": "batch", "entries": _erase_batch.duplicate()})
		_redo_stack.clear()
	_erase_batch = []
	queue_redraw()


# ============ 撤销 / 重做（独立于游戏撤销） ============

func _push_undo(entry: Dictionary) -> void:
	_undo_stack.push_back(entry)
	if _undo_stack.size() > UNDO_LIMIT:
		_undo_stack.pop_front()


func undo() -> void:
	if _undo_stack.is_empty():
		return
	var e: Dictionary = _undo_stack.pop_back()
	_apply_forward_inverse(e)
	_redo_stack.push_back(e)
	queue_redraw()
	changed.emit()


func redo() -> void:
	if _redo_stack.is_empty():
		return
	var e: Dictionary = _redo_stack.pop_back()
	_apply_forward(e)
	_undo_stack.push_back(e)
	queue_redraw()
	changed.emit()


## 反向执行（撤销）：add→移除；remove→恢复；replace→拆掉新段、还原原笔；batch→逆序撤销各子项
func _apply_forward_inverse(e: Dictionary) -> void:
	match e["op"]:
		"add":
			for s in e["strokes"]:
				strokes.erase(s)
		"remove":
			for s in e["strokes"]:
				strokes.append(s)
		"replace":
			for s in e["added"]:
				strokes.erase(s)
			for s in e["removed"]:
				strokes.append(s)
		"batch":
			var subs: Array = e["entries"]
			for i in range(subs.size() - 1, -1, -1):
				_apply_forward_inverse(subs[i])


## 正向执行（重做）：与上面严格互逆
func _apply_forward(e: Dictionary) -> void:
	match e["op"]:
		"add":
			for s in e["strokes"]:
				strokes.append(s)
		"remove":
			for s in e["strokes"]:
				strokes.erase(s)
		"replace":
			for s in e["removed"]:
				strokes.erase(s)
			for s in e["added"]:
				strokes.append(s)
		"batch":
			for sub in e["entries"]:
				_apply_forward(sub)


# ============ 清空 ============

## 清空全部绘画（压入撤销栈，可撤销恢复）
func clear_all() -> void:
	if strokes.is_empty():
		return
	_push_undo({"op": "remove", "strokes": strokes.duplicate()})
	_redo_stack.clear()
	strokes.clear()
	queue_redraw()
	changed.emit()


## 硬清空（重开关卡用，不保留撤销）
func clear_strokes() -> void:
	strokes.clear()
	_undo_stack.clear()
	_redo_stack.clear()
	_active_stroke = {}
	_erase_batch = []
	queue_redraw()
	changed.emit()


func has_strokes() -> bool:
	return not strokes.is_empty()


# ============ 渲染 ============

func _draw() -> void:
	for s in strokes:
		var col: Color = s["color"]
		var w: int = int(s["size"])
		var raw: PackedVector2Array = s["points"]
		if raw.is_empty():
			continue
		# 笔迹以棋盘坐标存储，绘制前换算回屏幕（棋盘缩放/平移由此自动跟随）
		var pts := PackedVector2Array()
		for p in raw:
			pts.append(_to_screen(p))
		if pts.size() == 1:
			draw_circle(pts[0], w * 0.5, col)
		else:
			# 连线 + 关节圆点。采样节流后点数已大幅下降，这里不再额外抽稀，
			# 否则快速书写的笔画会出现明显的折线感。
			draw_polyline(pts, col, float(w), true)
			for p in pts:
				draw_circle(p, w * 0.5, col)


# ============ 序列化（存档） ============

func get_save_data() -> Dictionary:
	var out: Array = []
	for s in strokes:
		var pts: Array = []
		for p in s["points"]:
			pts.append([p.x, p.y])
		out.append({
			"points": pts,
			"color": (s["color"] as Color).to_html(),
			"size": int(s["size"]),
			"is_eraser": bool(s.get("is_eraser", false)),
		})
	return {
		"v": SAVE_VERSION,
		"strokes": out,
		"current_color": current_color,
		"current_size": current_size,
	}


## 上次 load_save_data 是否因「旧版（v1 屏幕坐标）」而丢弃了笔迹。
## 供 UI 层给出明确提示，避免玩家以为笔迹凭空消失。
var _legacy_discarded := false


func legacy_discarded() -> bool:
	return _legacy_discarded


func load_save_data(data: Dictionary) -> void:
	clear_strokes()
	_legacy_discarded = false
	if data.is_empty():
		return
	if int(data.get("v", 1)) < SAVE_VERSION:
		_legacy_discarded = true
		changed.emit()
		return
	for sd in data.get("strokes", []):
		var pts := PackedVector2Array()
		for p in sd.get("points", []):
			if p is Array and p.size() == 2:
				pts.append(Vector2(float(p[0]), float(p[1])))
		if pts.is_empty():
			continue
		strokes.append({
			"points": pts,
			"color": Color.from_string(str(sd.get("color", "#FFFFFF")), Color.WHITE),
			"size": int(sd.get("size", 4)),
			"is_eraser": bool(sd.get("is_eraser", false)),
		})
	# 坏档防御：手改存档的大值此前会让 _start_draw 的 SIZES[current_size] 越界
	current_color = clampi(int(data.get("current_color", 0)), 0, COLOR_COUNT - 1)
	current_size = clampi(int(data.get("current_size", 1)), 0, SIZES.size() - 1)
	_undo_stack.clear()
	_redo_stack.clear()
	queue_redraw()
	changed.emit()


# ============ 主题透明度 ============

## 统一刷新不透明度：设置项 = 绘画模式下的浓度；非绘画模式再乘 DIM_FACTOR 作草稿态淡化
func _refresh_modulate() -> void:
	var base: float = 1.0
	if SettingsManager != null:
		base = clampf(SettingsManager.drawing_opacity, 0.5, 1.0)
	modulate = Color(1, 1, 1, base * (1.0 if paint_mode else DIM_FACTOR))
	queue_redraw()


func _on_settings_changed() -> void:
	_refresh_modulate()
