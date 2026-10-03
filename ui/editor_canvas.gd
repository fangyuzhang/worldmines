class_name EditorCanvas
extends Control

## 编辑器画布（P2）：格位绘制 + 笔刷输入 + 缩放平移 + 错误高亮。
##
## 【为什么不复用 board_view】
## `ui/board_view.gd` 的坐标/布局数学与**游戏**深度绑定（HUD 槽位、宠物停靠、提示面板、
## 泛洪动画、触摸手势…），拿它当画布要拆掉的比留下的多，而且它的 `_cell_at` 语义是
## "玩家点开一格"（含翻开/插旗/胜负判定），与编辑器的"改数据"完全不是一回事。
## 这里只保留一层：**格坐标 ⇄ 屏幕矩形**（照 board_view 的 scale-to-fit 思路写，但独立）。
##
## 【职责边界】本类**只**做两件事：把 doc 画出来、把鼠标动作翻译成"改哪一格"。
## 撤销栈、面板、存读、验证都在 `ui/level_editor.gd`（画布不该知道存档与 UI 面板的存在）。
##
## 【大棋盘不卡的三条】① 采样节流（鼠标拖动按最小间距过滤，照绘画层范式）；
## ② 只画可见区域的格（视口裁剪）；③ 编辑后不做全盘重算——由编辑器负责增量刷新预览值。

signal cell_edited(pos: Vector2i)      # 用户改了一格（编辑器据此刷新预览/标脏）
signal cell_edit_started(pos: Vector2i) # **开始**改（按下左键那一刻）——撤销点必须在这里取
signal selection_changed(rect: Rect2i)

enum Tool { PAINT, ERASE, RECT_FILL, SELECT, PAN }

## 单元格型（编辑器的"画笔颜色"）。与 `Cell`/`Cell.State` 的映射见 `_apply_kind`。
const KIND_MINE := "mine"
const KIND_OBSTACLE := "obstacle"
const KIND_REVEAL := "reveal"
const KIND_CLEAR := "clear"

## 单格边长下限。刻意取小（3px）：它是"缩到最小能看见整盘"的保障——
## 原先 6px 会让小窗口里的大盘永远看不全（只能靠平移找格子）。
## 放大靠 zoom（0.2~8），所以下限小一点不会影响正常编辑手感。
const MIN_CELL_PX := 3.0
const MAX_CELL_PX := 72.0
const DRAG_MIN_PX := 2.5               # 采样节流：小于此位移不重复应用笔刷

var doc: EditorDoc = null
var tool: int = Tool.PAINT
var paint_kind: String = KIND_MINE
var zoom := 1.0
var pan := Vector2.ZERO
var values: Dictionary = {}            # 预览线索值：Vector2i -> Variant
var highlight: Array[Vector2i] = []    # 错误/警告格的坐标（UI 高亮）
var hover := Vector2i(-1, -1)
var selection := Rect2i()

var _drag_start := Vector2i(-1, -1)
var _dragging := false
## 【用户需求 2026-10-02】右键 = 橡皮：按下擦该格、按住拖动连擦（见 `_erase_cell`）。
var _right_erasing := false
var _panning := false
var _last_mouse := Vector2.ZERO
var _rect_preview := Rect2i()

const _FONT := preload("res://ui/ui_fonts.gd")


func _init() -> void:
	name = "EditorCanvas"
	# MOUSE_FILTER_STOP：画布要自己吃掉鼠标事件（否则外层滚动容器会把拖动当成滚动）
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


func set_doc(p_doc: EditorDoc) -> void:
	doc = p_doc
	zoom = 1.0
	pan = Vector2.ZERO
	queue_redraw()


func set_values(v: Dictionary) -> void:
	values = v
	queue_redraw()


func set_highlight(cells: Array[Vector2i]) -> void:
	highlight = cells
	queue_redraw()


func set_selection(rect: Rect2i) -> void:
	selection = rect
	selection_changed.emit(selection)
	queue_redraw()


# ==================== 坐标换算 ====================

## 单格边长：按"能放下整盘"拟合，再乘缩放；上下各有夹取（太小看不清、太大没意义）。
func cell_px() -> float:
	if doc == null or doc.rows <= 0 or doc.cols <= 0:
		return MIN_CELL_PX
	var fit := minf(size.x / float(doc.cols), size.y / float(doc.rows))
	return clampf(fit * 0.94 * zoom, MIN_CELL_PX, MAX_CELL_PX)


func board_origin() -> Vector2:
	if doc == null:
		return Vector2.ZERO
	var total := Vector2(doc.cols, doc.rows) * cell_px()
	return (size - total) * 0.5 + pan


func cell_rect(pos: Vector2i) -> Rect2:
	var p := board_origin() + Vector2(pos.x, pos.y) * cell_px()
	return Rect2(p, Vector2(cell_px(), cell_px()))


## 屏幕点 → 格坐标；盘外返回 (-1,-1)。
func pos_at(local: Vector2) -> Vector2i:
	if doc == null:
		return Vector2i(-1, -1)
	var cp := cell_px()
	var rel := local - board_origin()
	var x := int(floor(rel.x / cp))
	var y := int(floor(rel.y / cp))
	if x < 0 or y < 0 or x >= doc.cols or y >= doc.rows:
		return Vector2i(-1, -1)
	return Vector2i(x, y)


## 可见格范围（视口裁剪：大棋盘上只画看得见的那些，避免每帧几千次绘制）。
func _visible_range() -> Rect2i:
	if doc == null:
		return Rect2i()
	var cp := cell_px()
	var o := board_origin()
	var x0 := clampi(int(floor((-o.x) / cp)), 0, doc.cols)
	var y0 := clampi(int(floor((-o.y) / cp)), 0, doc.rows)
	var x1 := clampi(int(ceil((size.x - o.x) / cp)), 0, doc.cols)
	var y1 := clampi(int(ceil((size.y - o.y) / cp)), 0, doc.rows)
	return Rect2i(x0, y0, maxi(x1 - x0, 0), maxi(y1 - y0, 0))


# ==================== 输入 ====================

func _gui_input(event: InputEvent) -> void:
	if doc == null:
		return
	if event is InputEventMouseButton:
		_handle_button(event)
	elif event is InputEventMouseMotion:
		_handle_motion(event)


func _handle_button(mb: InputEventMouseButton) -> void:
	var pos := pos_at(mb.position)
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
		_zoom_at(mb.position, 1.15)
		accept_event()
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
		_zoom_at(mb.position, 1.0 / 1.15)
		accept_event()
		return
	# 中键 = 临时平移（任何工具下都可用，符合画图软件习惯）
	if mb.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = mb.pressed
		_last_mouse = mb.position
		accept_event()
		return
	# 【用户需求 2026-10-02】**右键 = 橡皮**：一次擦掉该格；按住拖动 = 连续擦。
	# 设计取舍：① 不切换当前工具（擦完接着画，不用来回点「橡皮」按钮）；
	#           ② 编辑器里右键本来什么都不做，而小白的第一反应正是"右键擦/右键插旗"（实测过）。
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		_right_erasing = mb.pressed
		if mb.pressed:
			var rpos := pos_at(mb.position)
			_last_mouse = mb.position
			if rpos.x >= 0:
				_erase_cell(rpos)
		accept_event()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		_dragging = true
		_drag_start = pos
		_last_mouse = mb.position
		_rect_preview = Rect2i()
		if tool == Tool.PAN:
			_panning = true
			return
		if pos.x >= 0:
			if tool == Tool.PAINT or tool == Tool.ERASE:
				# 【W1】编辑器在收到 `cell_edit_started` 时**立刻**压撤销点（"改动之前"这条规矩）
				# ⇒ 必须**先**把这一格的"改动前状态"记进文档，否则那一刻 diff 还是空的、只拿得到快照。
				doc.note_cell(pos)
				# 撤销点必须在**改动之前**发出：编辑器据此存"改动前"的快照。
				# 若只在 `cell_edited`（改动之后）里存，撤销栈里全是"改完之后"的状态 ⇒
				# 按一次撤销等于没动、要按两次才退一步（2026-10-02 复查发现的真实缺陷）。
				# 每次手势只发一次（拖动中的移动不发）⇒ 一笔 = 一步撤销。
				cell_edit_started.emit(pos)
			_apply_tool(pos)
	elif _dragging:
		_dragging = false
		if tool == Tool.RECT_FILL and _drag_start.x >= 0 and pos.x >= 0:
			var box := Rect2i(_drag_start, pos - _drag_start).abs()
			# 【W1】整框先各记一次"改动前状态" ⇒ 这一步在撤销栈里是**一条 diff**（不是整盘快照），
			# 拉一次大框也只占"框内格数 × 12B"。
			for yy in range(box.position.y, box.position.y + box.size.y + 1):
				for xx in range(box.position.x, box.position.x + box.size.x + 1):
					doc.note_cell(Vector2i(xx, yy))
			cell_edit_started.emit(_drag_start)
			_fill_rect(box)
		elif tool == Tool.SELECT:
			set_selection(Rect2i(_drag_start, pos - _drag_start).abs())
		_rect_preview = Rect2i()
		queue_redraw()
	accept_event()


func _handle_motion(mm: InputEventMouseMotion) -> void:
	var pos := pos_at(mm.position)
	if pos != hover:
		hover = pos
		queue_redraw()
	if _panning:
		pan += mm.position - _last_mouse
		_last_mouse = mm.position
		queue_redraw()
		return
	# 右键擦除的拖动：与左键同规矩（节流 + 连续应用），但**一次手势只发一个撤销点**（见 fresh 参数）
	if _right_erasing:
		if pos.x >= 0 and mm.position.distance_to(_last_mouse) >= DRAG_MIN_PX:
			_last_mouse = mm.position
			_erase_cell(pos, false)
		return
	if not _dragging:
		return
	# 采样节流：位移过小不重复应用（拖动时鼠标事件密度远高于格子密度）
	if mm.position.distance_to(_last_mouse) < DRAG_MIN_PX:
		return
	_last_mouse = mm.position
	if tool == Tool.PAINT or tool == Tool.ERASE:
		if pos.x >= 0:
			_apply_tool(pos)
	elif tool == Tool.RECT_FILL or tool == Tool.SELECT:
		if _drag_start.x >= 0 and pos.x >= 0:
			_rect_preview = Rect2i(_drag_start, pos - _drag_start).abs()
			queue_redraw()


func _zoom_at(local: Vector2, factor: float) -> void:
	var before := (local - board_origin()) / maxf(cell_px(), 1.0)
	zoom = clampf(zoom * factor, 0.2, 8.0)
	var after := (local - board_origin()) / maxf(cell_px(), 1.0)
	pan += (after - before) * cell_px()
	queue_redraw()


# ==================== 工具 ====================

func _apply_tool(pos: Vector2i) -> void:
	match tool:
		Tool.PAINT:
			_apply_kind(pos, paint_kind)
		Tool.ERASE:
			_apply_kind(pos, KIND_CLEAR)
		_:
			return
	cell_edited.emit(pos)
	queue_redraw()


## 擦掉一格（右键路径，2026-10-02 用户需求）。
## `fresh=true` ⇒ 这次手势的**第一个**动作：撤销点在改动**之前**发（与左键同规矩，一笔 = 一步撤销）。
func _erase_cell(pos: Vector2i, fresh: bool = true) -> void:
	if fresh:
		doc.note_cell(pos)          # 【W1】同上：撤销点在改动之前，先记"改动前状态"
		cell_edit_started.emit(pos)
	_apply_kind(pos, KIND_CLEAR)
	cell_edited.emit(pos)
	queue_redraw()


func _fill_rect(rect: Rect2i) -> void:
	# 【审查 #（A3 同族）修】原来按 `p.x < doc.cols and p.y < doc.rows` 判界 —— 这是**包围盒**口径，
	# 对形状盘（蜂窝/三角/自定义）会把**洞格**也算进来，于是"刷一片障碍"会刷到盘外看不见的格上
	# （与 `_random_mines` 那次是同一个坑）。改成问网格：`in_board()`。
	for y in range(rect.position.y, rect.position.y + rect.size.y + 1):
		for x in range(rect.position.x, rect.position.x + rect.size.x + 1):
			var p := Vector2i(x, y)
			if doc.grid().in_board(p):
				_apply_kind(p, paint_kind)
	cell_edited.emit(rect.position)
	queue_redraw()


## 把"格型"落到文档（唯一的写入口；各工具的语义差异都在这里收口）。
## 注意互斥关系：雷 ↔ 障碍 ↔ 初始翻开是**互斥**的（同一格不能既是雷又是障碍），
## 这里显式清理，避免出现"既在 mines 又在 obstacles"这种 validate 才报警的状态。
func _apply_kind(pos: Vector2i, kind: String) -> void:
	if doc == null:
		return
	match kind:
		KIND_MINE:
			doc.obstacles.erase(pos)
			doc.revealed.erase(pos)
			if not doc.mines.has(pos):
				doc.mines.append(pos)
		KIND_OBSTACLE:
			doc.mines.erase(pos)
			doc.revealed.erase(pos)
			if not doc.obstacles.has(pos):
				doc.obstacles.append(pos)
		KIND_REVEAL:
			if not doc.mines.has(pos) and not doc.obstacles.has(pos):
				doc.revealed[pos] = null
		KIND_CLEAR:
			doc.mines.erase(pos)
			doc.obstacles.erase(pos)
			doc.revealed.erase(pos)
		_:
			pass


## 公开写入口（审查 D12：编辑器里原来有一份**重复实现** `level_editor._apply_kind_at`，
## 两份迟早分叉 ⇒ 收口到这里，编辑器（粘贴等路径）只调用本函数）。
func apply_kind(pos: Vector2i, kind: String) -> void:
	# 【W1】写盘前先让文档记下这格"改动前的状态"（撤销才有 diff 可回退）。
	# 放在这唯一写入口上 ⇒ 画笔/橡皮/右键擦/矩形填充/粘贴全部自动覆盖，不必逐处埋点。
	doc.note_cell(pos)
	_apply_kind(pos, kind)


# ==================== 绘制 ====================

func _draw() -> void:
	if doc == null or doc.rows <= 0 or doc.cols <= 0:
		return
	var cp := cell_px()
	var o := board_origin()
	var vis := _visible_range()

	# 棋盘底板（比格色深一点，形成"盘"的感觉）
	draw_rect(Rect2(o, Vector2(doc.cols, doc.rows) * cp), ThemeManager.board_mat(), true)

	var ms := doc.mine_set()
	var ob := {}
	for p in doc.obstacles:
		ob[p] = true
	var hl := {}
	for p in highlight:
		hl[p] = true
	var font := _FONT.digit()
	var font_size := int(clampf(cp * 0.62, 8.0, 34.0))

	for y in range(vis.position.y, vis.position.y + vis.size.y):
		for x in range(vis.position.x, vis.position.x + vis.size.x):
			var p := Vector2i(x, y)
			var r := cell_rect(p)
			var inner := Rect2(r.position + Vector2.ONE, r.size - Vector2(2, 2))
			var col := ThemeManager.cell_hidden()
			var is_mine := ms.has(p)
			var is_obs := ob.has(p)
			if is_obs:
				col = ThemeManager.board_mat().darkened(0.35)
			elif is_mine:
				# 雷格：用主题的"隐藏格色"加深。刻意**不**用 overlay 访问器——本仓主题
				# 只导出 cell_hidden/cell_revealed/text/accent/board_mat/number 这一组
				#（`ui/theme_manager.gd:1057-1085,1181,1318`），没有通用的 overlay 取值接口。
				col = ThemeManager.cell_hidden().darkened(0.25)
			elif doc.revealed.has(p):
				col = ThemeManager.cell_revealed()
			draw_rect(inner, col, true)
			if is_mine and not is_obs:
				# 雷画成实心圆点（比画贴图省事，且无头环境也不依赖纹理导入）
				draw_circle(inner.get_center(), mini(inner.size.x, inner.size.y) * 0.28,
					ThemeManager.cell_hidden().darkened(0.45))
			elif doc.revealed.has(p) and values.has(p):
				var v: Variant = values[p]
				# 只画正整数：0 = 空白格（主题的 number(0) 按约定不绘制），负数 = 不携带线索的哨兵。
				# font 为 null（字体资源缺失）时跳过绘制而不是把 null 交给 draw_string（会刷错）。
				if v is int and int(v) > 0 and font != null:
					var txt := str(int(v))
					var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
					draw_string(font, inner.position + Vector2((inner.size.x - w) * 0.5, inner.size.y * 0.76),
						txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ThemeManager.number(int(v)))
			if hl.has(p):
				draw_rect(inner, ThemeManager.accent(), false, 2.0)
			elif p == hover:
				draw_rect(inner, ThemeManager.accent(), false, 1.0)

	# 选区 / 填充预览
	var rect := _rect_preview if _rect_preview.size != Vector2i.ZERO else selection
	if (tool == Tool.SELECT or tool == Tool.RECT_FILL) and rect.size != Vector2i.ZERO:
		var a := cell_rect(rect.position).position
		var b := cell_rect(rect.position + rect.size).position + Vector2(cp, cp)
		draw_rect(Rect2(a, b - a), ThemeManager.accent(), false, 2.0)
