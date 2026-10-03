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
## 油漆桶结果：`filled`（染了几格）、`truncated`（是否触到访问上限）、`reason`（人话原因）。
## 编辑器可连它弹提示；不连也不影响填充（结果同时可从 `bucket_cells()` 取）。
signal bucket_reported(result: Dictionary)

## 工具枚举。**新工具一律追加在末尾**：`PAINT..PAN` 的序号被 `level_editor.gd` 的按钮表
## 与既有测试直接引用，插在中间会静默错位（改的是"按钮点到的工具"）。
enum Tool { PAINT, ERASE, RECT_FILL, SELECT, PAN, LINE, BUCKET }

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

# —— 网格线（2026-10-03，文档「一、基础操作」缺口）——
## 逐格画细网格线的格宽下限。**依据**：`draw_line` 次数 ∝ 可见线数 ≈ 2 × 画布边长 / 格宽；
## 格宽低于此值后细线已糊成一片（视觉零信息量）却仍在逐条提交绘制 ⇒ 正是"大棋盘逐格画到卡死"
## 的来源之一。故低于它改用粗网格（把线数按画布尺寸封顶，见 `grid_line_step()`）。
const GRID_THIN_MIN_PX := 6.0
## 粗网格目标线距（px）：格宽太小时每隔 `ceil(此值 / 格宽)` 格画一条。
const GRID_COARSE_TARGET_PX := 28.0

# —— 小地图（同文档缺口）——
const MINIMAP_MARGIN := 8.0            # 小地图与画布右下角的固定边距
const MINIMAP_FRACTION := 0.22         # 小地图宽度占画布宽度的比例
const MINIMAP_MIN_W := 72.0
const MINIMAP_MAX_W := 160.0
const MINIMAP_MAX_H_FRACTION := 0.4    # 小地图高度不超过画布高度的这个比例

# —— 油漆桶（同文档缺口）——
## 洪泛访问上限，**直接取** `EditorDoc.MAX_CELL_BUDGET`（单一真源，不写死数字，两处不会漂移）。
## **依据**：5000 格已是编辑器公认的"还能动"的上限；超过它意味着这盘本身会被尺寸闸门拦下，
## 洪泛再往下走只会白等 —— 到顶即停并给可读结果（`bucket_cells()` 的 `truncated/reason`）。
const BUCKET_VISIT_LIMIT := EditorDoc.MAX_CELL_BUDGET

# —— 静态层缓存（文档「十.4」：5000 格棋盘不能逐帧重绘）——
## 静态层 = 「棋盘底板 + 逐格底色 + 网格线」这三类**只随格子集/尺寸/主题变**的内容。
## 它们被画进一张 `ImageTexture` 缓存：格数再多，每帧也只提交 1 次 `draw_texture`
##（而不是几千次 `draw_rect`/`draw_line`）。动态层（悬停 / 高亮 / 叠加 / 选区 / 数字 /
## 线预览 / 小地图）**永远实时画**，不受缓存影响。
##
## 【为什么缓存是"盘局部"而不是"画布局部"】纹理按「整盘 @ 当前格宽」生成，绘制时只做平移
## ⇒ 平移（pan）不触发重建，只有缩放（格宽变了）/ 换盘 / 改格子集 / 换主题才重建。
## 否则每拖一下视口都要重画整盘，"缓存"反而更慢。
const STATIC_CACHE_MAX_EDGE := 8192          # 纹理单边上限（照常见 GPU 纹理上限取）
const STATIC_CACHE_MAX_PIXELS := 8_000_000   # 纹理面积上限（≈32MB RGBA8）——超了不缓存，直绘

# —— 正式叠加 API（逐格数据的正式接口，见 `set_overlay`）——
## 颜色纪律：**红/蓝一律来自 `ThemeManager`**（`danger()` / `accent()`），
## 本文件只决定「深度 → 透明度」，不出现任何硬编码 RGB。
const OVERLAY_MUST_GUESS_ALPHA := 0.55       # 必猜格（红）的固定透明度
const OVERLAY_DEPTH_ALPHA_MIN := 0.10        # 深度最浅（早推出）的透明度
const OVERLAY_DEPTH_ALPHA_MAX := 0.45        # 深度最深（晚推出）的透明度

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
## 网格线显隐（编辑器「显示」区可接；见 `grid_line_step()`）。
var show_grid := true
## 空格平移态：键盘在 `level_editor.gd` 侧监听，画布只通过 `set_pan_mode()` 收结果。
var _pan_mode := false
## 直线工具起点（按下那一刻）；(-1,-1) = 当前没有进行中的直线。
var _line_anchor := Vector2i(-1, -1)
## 直线工具预览格集合（拖动中随鼠标更新）。
var _line_preview: Array[Vector2i] = []
## 小地图拖动中（点/拖小地图 = 移动视口）。
var _minimap_dragging := false

## 正式叠加层：name -> {cells: Dictionary, opts: Dictionary}。多层共存、可整体清除。
## `cells` 形如 Vector2i -> {level:int, must_guess:bool}（与 `HotMap.build()` 的输出同构）。
var _overlays: Dictionary = {}

# —— 静态层缓存状态（全部可观察，供单测断言；不依赖像素比对）——
var _static_cache: ImageTexture = null       # 空 = 无缓存（降级态或尚未构建）
var _static_cache_key := ""                  # 当前缓存对应的"静止内容指纹"（见 `_static_key`）
var _static_dirty := true                    # 需要（重）建
var _static_cache_builds := 0                # （重）建次数（降级时也计数，见 `ensure_static_cache`）
var _static_invalidations := 0               # 显式失效请求次数
var _static_invalidate_note := ""            # 最近一次失效原因（排查用）
var _static_degraded_reason := ""            # 非空 = 正在走"不缓存、直绘"降级路径，值为原因
var _static_direct_draws := 0                # 降级路径（每帧直绘静态层）被执行的次数

const _FONT := preload("res://ui/ui_fonts.gd")


func _init() -> void:
	name = "EditorCanvas"
	# MOUSE_FILTER_STOP：画布要自己吃掉鼠标事件（否则外层滚动容器会把拖动当成滚动）
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	# 静态层缓存是"像素级"纹理（1:1 绘制）：用 NEAREST 避免半像素偏移把它糊掉。
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _ready() -> void:
	# 主题过渡（300ms）里每步都发 `theme_changed` ⇒ 静态层颜色随中间态一起更新，
	# 否则缓存会把换肤前的旧色钉在盘上。
	if not ThemeManager.theme_changed.is_connected(_on_theme_changed):
		ThemeManager.theme_changed.connect(_on_theme_changed)


func _on_theme_changed() -> void:
	invalidate_static_cache("主题切换")
	queue_redraw()


func set_doc(p_doc: EditorDoc) -> void:
	doc = p_doc
	zoom = 1.0
	pan = Vector2.ZERO
	invalidate_static_cache("换文档")
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


## 空格平移态（文档「一、基础操作」）：按住空格 = 左键拖动变成平移，不再触发绘制。
## 【为什么画布只收结果】键盘监听归 `level_editor.gd`（界面层的事），画布只暴露这条接口，
## 两条路径（空格 / 中键 / `Tool.PAN`）最终共用同一段 `_panning` 逻辑，不会分叉。
func set_pan_mode(on: bool) -> void:
	_pan_mode = on
	if not on:
		_panning = false
	mouse_default_cursor_shape = Control.CURSOR_MOVE if on else Control.CURSOR_ARROW


## 网格线显示开关（编辑器「显示」区可接）。
## 【文档「七」：一键显雷（仅编辑态）】`false` 时不画雷。
## 为什么之前"点了没用"：`ui/level_editor.gd:3303` 是 **duck-typing** 调用
## `if canvas.has_method("set_show_mines")`，而本文件**没有这个方法** ⇒ 开关静默失效。
## 判定口径仍只有一处：`EditorViewState.is_cheat_visible()`（试玩态强制隐藏），画布只是执行者。
var show_mines := true


func set_show_mines(on: bool) -> void:
	if show_mines == on:
		return
	show_mines = on
	invalidate_static_cache("显雷开关")
	queue_redraw()


func set_show_grid(on: bool) -> void:
	show_grid = on
	invalidate_static_cache("网格线开关")
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


# ==================== 小地图（纯函数，可单测） ====================

## 棋盘是否超出可视区域（= 该画小地图的条件）。
func board_overflows_view() -> bool:
	if doc == null or doc.rows <= 0 or doc.cols <= 0:
		return false
	var cp := cell_px()
	return float(doc.cols) * cp > size.x + 0.5 or float(doc.rows) * cp > size.y + 0.5


## 小地图矩形（画布局部坐标）。棋盘没超出可视区域 ⇒ 返回空 `Rect2`（不画）。
## 【纯函数】只依赖 `doc.rows/cols`、`cell_px()` 与 `size`，不碰绘制、不碰输入 ⇒ 可单测。
## 小地图按棋盘长宽比缩放，固定在右下角，留 `MINIMAP_MARGIN` 边距。
func minimap_rect() -> Rect2:
	if not board_overflows_view():
		return Rect2()
	var w := clampf(size.x * MINIMAP_FRACTION, MINIMAP_MIN_W, MINIMAP_MAX_W)
	var h := w * float(doc.rows) / float(doc.cols)
	var max_h := size.y * MINIMAP_MAX_H_FRACTION
	if h > max_h:
		h = max_h
		w = h * float(doc.cols) / float(doc.rows)
	# 边界：极小画布时小地图不得比画布还大（否则退化成一块糊满的色块）
	w = minf(w, size.x - MINIMAP_MARGIN * 2.0)
	h = minf(h, size.y - MINIMAP_MARGIN * 2.0)
	if w <= 0.0 or h <= 0.0:
		return Rect2()
	return Rect2(size.x - w - MINIMAP_MARGIN, size.y - h - MINIMAP_MARGIN, w, h)


## 小地图坐标 → 棋盘格（点/拖小地图移动视口用）。无小地图时返回 (-1,-1)。
func minimap_to_cell(local: Vector2) -> Vector2i:
	var mr := minimap_rect()
	if mr.size.x <= 0.0 or mr.size.y <= 0.0:
		return Vector2i(-1, -1)
	var fx := clampf((local.x - mr.position.x) / mr.size.x, 0.0, 1.0)
	var fy := clampf((local.y - mr.position.y) / mr.size.y, 0.0, 1.0)
	return Vector2i(clampi(int(fx * float(doc.cols)), 0, doc.cols - 1),
		clampi(int(fy * float(doc.rows)), 0, doc.rows - 1))


## 把视口中心移到某格（小地图点击/拖动用）。
func center_on_cell(p: Vector2i) -> void:
	if doc == null:
		return
	var cp := cell_px()
	# 由 board_origin() = (size - total)/2 + pan 反解：让格心落在画布中心。
	pan = Vector2(float(doc.cols) * 0.5 - (p.x + 0.5), float(doc.rows) * 0.5 - (p.y + 0.5)) * cp
	queue_redraw()


# ==================== 网格线决策（纯函数，可单测） ====================

## 网格线绘制步长：0 = 不画；1 = 逐格细线；>1 = 每隔该格数画一条（粗网格）。
## 【大棋盘依据】线数 ≈ 画布边长 / (格宽 × 步长)，步长按 `GRID_COARSE_TARGET_PX` 反推 ⇒
## 线数被画布尺寸封顶（与格数无关），大棋盘不会再"逐格画到卡死"。
func grid_line_step() -> int:
	if not show_grid or doc == null or doc.rows <= 0 or doc.cols <= 0:
		return 0
	var cp := cell_px()
	if cp >= GRID_THIN_MIN_PX:
		return 1
	return maxi(1, ceili(GRID_COARSE_TARGET_PX / cp))


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
	# 小地图：左键点/拖 = 移动视口。**必须在任何绘制工具之前拦下**——否则点小地图会顺手画一格。
	if mb.button_index == MOUSE_BUTTON_LEFT and minimap_rect().has_point(mb.position):
		_minimap_dragging = mb.pressed
		if mb.pressed:
			center_on_cell(minimap_to_cell(mb.position))
		accept_event()
		return
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
		_line_preview = []
		if tool == Tool.PAN or _pan_mode:
			# 空格平移态与 `Tool.PAN` 共用同一条路径（见 `set_pan_mode`）。
			_panning = true
			accept_event()
			return
		if pos.x >= 0:
			# 油漆桶：按下即填（无拖动语义）。撤销点由 `_apply_bucket` 在改动前取。
			if tool == Tool.BUCKET:
				_apply_bucket(pos)
				return
			# 直线：按下只记锚点 + 预览，抬起才落笔（一笔 = 一步撤销）。
			if tool == Tool.LINE:
				_line_anchor = pos
				_line_preview = [pos]
				queue_redraw()
				return
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
		# 【顺带修的真缺陷】`Tool.PAN` / 空格平移在按下时置 `_panning=true`，原先抬起**没清**它
		# ⇒ 松手后鼠标一动仍整盘跟着跑（平移"粘住"）。抬起即结束平移。
		_panning = false
		if tool == Tool.RECT_FILL and _drag_start.x >= 0 and pos.x >= 0:
			var box := Rect2i(_drag_start, pos - _drag_start).abs()
			# 【W1】整框先各记一次"改动前状态" ⇒ 这一步在撤销栈里是**一条 diff**（不是整盘快照），
			# 拉一次大框也只占"框内格数 × 12B"。
			for yy in range(box.position.y, box.position.y + box.size.y + 1):
				for xx in range(box.position.x, box.position.x + box.size.x + 1):
					doc.note_cell(Vector2i(xx, yy))
			cell_edit_started.emit(_drag_start)
			_fill_rect(box)
		elif tool == Tool.LINE and _line_anchor.x >= 0 and pos.x >= 0:
			_apply_line(_line_anchor, pos)
		elif tool == Tool.SELECT:
			set_selection(Rect2i(_drag_start, pos - _drag_start).abs())
		_line_anchor = Vector2i(-1, -1)
		_line_preview = []
		_rect_preview = Rect2i()
		queue_redraw()
	accept_event()


func _handle_motion(mm: InputEventMouseMotion) -> void:
	var pos := pos_at(mm.position)
	if pos != hover:
		hover = pos
		queue_redraw()
	if _minimap_dragging:
		center_on_cell(minimap_to_cell(mm.position))
		return
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
	elif tool == Tool.LINE:
		if _line_anchor.x >= 0 and pos.x >= 0:
			_line_preview = line_cells(_line_anchor, pos)
			queue_redraw()
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


# —— 直线工具（Tool.LINE）——

## 格点直线：Bresenham，返回从 `a` 到 `b` 经过的**全部格坐标**（含两端，`[a, b]` 对称）。
## 【纯函数】只做整数运算、不碰文档/绘制 ⇒ 可单测（测试钉"命中格集合正确"）。
static func line_cells(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var x0 := a.x
	var y0 := a.y
	var x1 := b.x
	var y1 := b.y
	var dx := absi(x1 - x0)
	var sx := 1 if x0 < x1 else -1
	var dy := -absi(y1 - y0)
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	while true:
		out.append(Vector2i(x0, y0))
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
	return out


## 落一条直线（抬起那一刻调）。复用 `_apply_kind` 与当前 `paint_kind`。
## 判界口径：问网格 `in_board()`（形状盘上两点之间的线可能经过盘外空位）。
func _apply_line(a: Vector2i, b: Vector2i) -> void:
	if doc == null:
		return
	var g := doc.grid()
	var cells := line_cells(a, b)
	# 与矩形填充同规矩：整条线先各记一次"改动前状态" ⇒ 一步撤销一条 diff。
	for p in cells:
		if g.in_board(p):
			doc.note_cell(p)
	cell_edit_started.emit(a)
	for p in cells:
		if g.in_board(p):
			_apply_kind(p, paint_kind)
	cell_edited.emit(b)
	queue_redraw()


# —— 油漆桶（Tool.BUCKET）——

## 一格的"格型"（与 `_apply_kind` 的三集合互斥语义同口径）。
func cell_kind(p: Vector2i) -> String:
	if doc == null:
		return KIND_CLEAR
	if doc.mines.has(p):
		return KIND_MINE
	if doc.obstacles.has(p):
		return KIND_OBSTACLE
	if doc.revealed.has(p):
		return KIND_REVEAL
	return KIND_CLEAR


## 三集合 → 格型映射（洪泛内层循环用它做 O(1) 查询，避免逐格 `.has()` 的线性扫描）。
func _kind_map() -> Dictionary:
	var m := {}
	if doc == null:
		return m
	for p in doc.mines:
		m[p] = KIND_MINE
	for p in doc.obstacles:
		m[p] = KIND_OBSTACLE
	for p in doc.revealed:
		m[p] = KIND_REVEAL
	return m


## 从 `seed` 出发，按**同一格型**洪泛（邻接问 `doc.grid()`，绝不自己拼 4 邻域——异形盘的
## 邻接表、环绕盘的回绕都由网格给，自己拼必然分叉）。
##
## 返回 `{cells: Array[Vector2i], filled: int, truncated: bool, reason: String}`。
## 【访问上限】`limit`（默认 `BUCKET_VISIT_LIMIT`）到顶即停（`truncated=true`、`reason` 给原因），
## 防"点一下卡死"：5000 格连通区在大盘上是常态，不设限就会同步洪泛到天荒地老。
## `limit` 可注入只为**单测**能用小盘验截断（默认值仍是生产口径）。
func bucket_cells(seed: Vector2i, limit: int = BUCKET_VISIT_LIMIT) -> Dictionary:
	var cap := maxi(limit, 1)
	var out := {"cells": [], "filled": 0, "truncated": false, "reason": ""}
	if doc == null or not doc.grid().in_board(seed):
		out["reason"] = "起点不在盘上"
		return out
	var g := doc.grid()
	var kinds := _kind_map()
	var target: String = String(kinds.get(seed, KIND_CLEAR))
	var seen := {seed: true}
	var queue: Array[Vector2i] = [seed]
	var cells: Array[Vector2i] = []
	while not queue.is_empty():
		var p: Vector2i = queue.pop_back()
		cells.append(p)
		if cells.size() >= cap:
			out["truncated"] = true
			out["reason"] = "填充区域超过 %d 格上限，已停止（再往下填只会卡住）" % cap
			break
		for nb in g.get_neighbors(p):
			if seen.has(nb):
				continue
			if not g.in_board(nb):
				continue
			if String(kinds.get(nb, KIND_CLEAR)) != target:
				continue
			seen[nb] = true
			queue.append(nb)
	out["cells"] = cells
	out["filled"] = cells.size()
	return out


## 落一次油漆桶填充（按下即调）。与矩形填充同规矩：整块先记"改动前状态"，一步 = 一条 diff。
func _apply_bucket(seed: Vector2i) -> void:
	if doc == null:
		return
	var res := bucket_cells(seed)
	var cells: Array = res.get("cells", [])
	if cells.is_empty():
		bucket_reported.emit(res)
		return
	# 同型填充（例如对一片"空"再刷"空"）不写盘、不占撤销栈。
	if paint_kind == cell_kind(seed):
		bucket_reported.emit(res)
		return
	for p in cells:
		doc.note_cell(p)
	cell_edit_started.emit(seed)
	for p in cells:
		_apply_kind(p, paint_kind)
	cell_edited.emit(seed)
	bucket_reported.emit(res)
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
	# 格子底色变了 ⇒ 静态层缓存作废（这里是所有写路径的唯一收口，见 ensure_static_cache）。
	_static_dirty = true


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

	# ---- 静态层：底板 + 逐格底色 + 网格线（缓存；降级口径见 `ensure_static_cache`）----
	if ensure_static_cache():
		draw_texture(_static_cache, o)
	else:
		_static_direct_draws += 1
		_paint_static_canvas(self, vis)

	# ---- 动态层：以下内容**永远实时画**（悬停 / 高亮 / 叠加 / 选区 / 数字 / 预览 / 小地图）----
	# 显雷开关关闭时取空集：雷的**底色加深**（静态层）与**实心圆点**（这里）都不画。
	var ms := doc.mine_set() if show_mines else {}
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
			var is_mine := ms.has(p)
			var is_obs := doc.obstacles.has(p)
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

	# 叠加层（正式 API：多层、颜色走主题；见 `set_overlay`）
	_draw_overlays(vis)

	# 直线工具预览（拖动中“待落笔”的那条线）
	if tool == Tool.LINE and _dragging and not _line_preview.is_empty():
		for lp in _line_preview:
			draw_rect(cell_rect(lp), ThemeManager.accent(), false, 2.0)

	# 选区 / 填充预览
	var rect := _rect_preview if _rect_preview.size != Vector2i.ZERO else selection
	if (tool == Tool.SELECT or tool == Tool.RECT_FILL) and rect.size != Vector2i.ZERO:
		var a := cell_rect(rect.position).position
		var b := cell_rect(rect.position + rect.size).position + Vector2(cp, cp)
		draw_rect(Rect2(a, b - a), ThemeManager.accent(), false, 2.0)

	# 小地图（棋盘超出可视区域时；几何全由 `minimap_rect()` 决定 ⇒ 可单测）
	_draw_minimap()


## 静态层直绘路径（**降级**用：无头 / 纹理超预算时走这里，每帧直绘）。
## 与缓存路径共用 `_cell_fill_color` 与 `grid_line_step` ⇒ 颜色/网格策略不会分叉。
func _paint_static_canvas(ci: CanvasItem, vis: Rect2i) -> void:
	var cp := cell_px()
	# 棋盘底板（比格色深一点，形成"盘"的感觉）
	ci.draw_rect(Rect2(board_origin(), Vector2(doc.cols, doc.rows) * cp), ThemeManager.board_mat(), true)
	var ms := doc.mine_set() if show_mines else {}
	var ob := {}
	for p in doc.obstacles:
		ob[p] = true
	for y in range(vis.position.y, vis.position.y + vis.size.y):
		for x in range(vis.position.x, vis.position.x + vis.size.x):
			var p := Vector2i(x, y)
			var r := cell_rect(p)
			var inner := Rect2(r.position + Vector2.ONE, r.size - Vector2(2, 2))
			ci.draw_rect(inner, _cell_fill_color(p, ms, ob), true)
	var step := grid_line_step()
	if step > 0:
		_draw_grid(ci, cp, board_origin(), vis, step)


## 一格底色（静态层用）。**唯一的格色决策点**：缓存路径与直绘路径都调它，避免两份实现漂移。
## 颜色全部来自 `ThemeManager`（本文件不硬编码 RGB）。
func _cell_fill_color(p: Vector2i, ms: Dictionary, ob: Dictionary) -> Color:
	if ob.has(p):
		return ThemeManager.board_mat().darkened(0.35)
	if ms.has(p):
		# 雷格：用主题的"隐藏格色"加深。刻意**不**用 overlay 访问器——本仓主题
		# 只导出 cell_hidden/cell_revealed/text/accent/board_mat/number 这一组
		#（`ui/theme_manager.gd:1057-1085,1181,1318`），没有通用的 overlay 取值接口。
		return ThemeManager.cell_hidden().darkened(0.25)
	if doc.revealed.has(p):
		return ThemeManager.cell_revealed()
	return ThemeManager.cell_hidden()


## 画网格线。只画**可见范围内**的线，且按 `step` 抽稀（大棋盘粗网格）。
## 线索引对齐到 step 的整数倍 ⇒ 平移时线不会随视口滑动。
func _draw_grid(ci: CanvasItem, cp: float, o: Vector2, vis: Rect2i, step: int) -> void:
	var col := ThemeManager.board_grid()   # 棋盘格线专用色（走主题，勿硬编码）
	var x1 := vis.position.x + vis.size.x
	var y1 := vis.position.y + vis.size.y
	var top := o.y + float(vis.position.y) * cp
	var bot := o.y + float(y1) * cp
	var x := int(ceil(float(vis.position.x) / float(step))) * step
	while x <= x1:
		var sx := o.x + float(x) * cp
		ci.draw_line(Vector2(sx, top), Vector2(sx, bot), col, 1.0)
		x += step
	var left := o.x + float(vis.position.x) * cp
	var right := o.x + float(x1) * cp
	var y := int(ceil(float(vis.position.y) / float(step))) * step
	while y <= y1:
		var sy := o.y + float(y) * cp
		ci.draw_line(Vector2(left, sy), Vector2(right, sy), col, 1.0)
		y += step


## 画小地图：底板 + 当前视口矩形（棋盘范围就是底板本身，按 `minimap_rect()` 的长宽比还原）。
func _draw_minimap() -> void:
	var mr := minimap_rect()
	if mr.size.x <= 0.0 or mr.size.y <= 0.0:
		return
	draw_rect(mr, ThemeManager.card(), true)
	draw_rect(mr, ThemeManager.board_grid(), false, 1.0)
	var vis := _visible_range()
	var vr := Rect2(
		mr.position + Vector2(float(vis.position.x) / float(doc.cols),
			float(vis.position.y) / float(doc.rows)) * mr.size,
		Vector2(float(vis.size.x) / float(doc.cols), float(vis.size.y) / float(doc.rows)) * mr.size)
	draw_rect(vr.intersection(mr), ThemeManager.accent(), false, 1.5)


# ==================== 正式叠加 API（逐格数据的正式接口） ====================
#
# 【替代什么】在此之前，"叠加"是**运行期**往画布挂一个子 Control（`level_editor.gd` 的内层类
# `HotOverlay`）来复用 `cell_rect()` 实现的：颜色是硬编码 RGB、且"叠加"这件事散在编辑器里。
# 现在画布自己就是唯一实现：接受「坐标 → {level, must_guess}」，颜色一律走 `ThemeManager`。
#
# 【向后兼容】本 API 是**新增**的 —— `set_highlight` / `set_values` / `set_selection` 行为一字未变；
# 编辑器暂不调用它也不会坏（旧 `HotOverlay` 路径照常工作）。

## 设置/覆盖一层叠加数据。
## `cells`：Vector2i -> {level:int, must_guess:bool}（与 `HotMap.build()` 的 cells 同构，多余键忽略）。
## `opts`（全部可选）：`max_level`（深度归一上限，<=0 时用本层数据里的最大 level）、`z`（层序）、
## `visible`（bool）、`must_alpha` / `alpha_min` / `alpha_max`（透明度）。
func set_overlay(name: String, cells: Dictionary, opts: Dictionary = {}) -> void:
	if name.is_empty():
		return
	_overlays[name] = {"cells": cells, "opts": opts}
	queue_redraw()


## 清除某一层（不存在则无操作）。
func clear_overlay(name: String) -> void:
	if _overlays.erase(name):
		queue_redraw()


## 整体清除所有叠加层。
func clear_overlays() -> void:
	if _overlays.is_empty():
		return
	_overlays.clear()
	queue_redraw()


## 显隐某一层（**保留数据**，只控制是否绘制）。与 `opts.visible` 是同一个开关——
## 编辑器里"热力图开关"要能"关掉但不丢结果"，下一步不该重新跑求解器。
func set_overlay_visible(name: String, on: bool) -> void:
	var layer: Variant = _overlays.get(name)
	if not (layer is Dictionary):
		return
	var opts: Dictionary = (layer as Dictionary).get("opts", {})
	opts["visible"] = on
	queue_redraw()


func has_overlay(name: String) -> bool:
	return _overlays.has(name)


## 全部层名（按名字升序；与绘制顺序无关，仅便于列表/测试）。
func overlay_names() -> Array:
	var names: Array = _overlays.keys()
	names.sort()
	return names


## 取某层数据（不存在返回空 Dictionary）。
func get_overlay(name: String) -> Dictionary:
	return _overlays.get(name, {})


## 单格叠加色（**公开纯函数**，无副作用、不碰绘制 ⇒ 直接可单测）。
## 必猜格 = 红（`ThemeManager.danger()`）；其余按深度用 `ThemeManager.accent()` 的**透明度**表达
##（浅 = 早推出，深 = 晚推出）。返回 alpha=0 表示"这格不涂"（level<0 且非必猜 ⇒ 留白，绝不假装知道）。
func overlay_cell_color(must_guess: bool, level: int, max_level: int, opts: Dictionary = {}) -> Color:
	if must_guess:
		var d := ThemeManager.danger()
		return Color(d.r, d.g, d.b, clampf(float(opts.get("must_alpha", OVERLAY_MUST_GUESS_ALPHA)), 0.0, 1.0))
	if level < 0:
		return Color(0, 0, 0, 0)
	var ml := int(opts.get("max_level", 0))
	if ml <= 0:
		ml = max_level
	if ml <= 0:
		ml = 1
	var t := clampf(float(level) / float(ml), 0.0, 1.0)
	var a_lo := float(opts.get("alpha_min", OVERLAY_DEPTH_ALPHA_MIN))
	var a_hi := float(opts.get("alpha_max", OVERLAY_DEPTH_ALPHA_MAX))
	var c := ThemeManager.accent()
	return Color(c.r, c.g, c.b, clampf(a_lo + (a_hi - a_lo) * t, 0.0, 1.0))


## 画所有叠加层：按 `z` 升序、同 `z` 按名字升序 ⇒ 绘制顺序确定、可复现。
## 只画可见范围内的格（视口裁剪），且**不盖小地图**（它是"看全局的眼睛"）。
func _draw_overlays(vis: Rect2i) -> void:
	if _overlays.is_empty() or vis.size.x <= 0 or vis.size.y <= 0:
		return
	var names := overlay_names()
	names.sort_custom(_overlay_order_before)
	var mm := minimap_rect()
	var mm_hit := mm.size.x > 0.0 and mm.size.y > 0.0
	for name in names:
		var layer: Dictionary = _overlays[name]
		var opts: Dictionary = layer.get("opts", {})
		if not bool(opts.get("visible", true)):
			continue
		var cells: Dictionary = layer.get("cells", {})
		var ml := int(opts.get("max_level", 0))
		if ml <= 0:
			ml = _overlay_max_level(cells)
		for key in cells:
			if not (key is Vector2i):
				continue
			var p: Vector2i = key
			if not vis.has_point(p):
				continue
			var raw: Variant = cells[key]
			if not (raw is Dictionary):
				continue
			var rec: Dictionary = raw
			var must := bool(rec.get("must_guess", false))
			var lv := int(rec.get("level", -1))
			if not must and lv < 0:
				continue
			var r := cell_rect(p)
			if mm_hit and mm.has_point(r.get_center()):
				continue
			var col := overlay_cell_color(must, lv, ml, opts)
			if col.a <= 0.0:
				continue
			draw_rect(r, col, true)


func _overlay_order_before(a: Variant, b: Variant) -> bool:
	var za := _overlay_z(String(a))
	var zb := _overlay_z(String(b))
	if za != zb:
		return za < zb
	return String(a) < String(b)


func _overlay_z(name: String) -> int:
	var layer: Dictionary = _overlays.get(name, {})
	var opts: Dictionary = layer.get("opts", {})
	return int(opts.get("z", 0))


## 本层数据的最大深度（`opts.max_level` 未给时的归一化上限）。
func _overlay_max_level(cells: Dictionary) -> int:
	var ml := 0
	for key in cells:
		var raw: Variant = cells[key]
		if raw is Dictionary:
			ml = maxi(ml, int((raw as Dictionary).get("level", -1)))
	return ml


# ==================== 静态层缓存（文档「十.4」） ====================
#
# 【要解决什么】5000 格棋盘上，逐格 `draw_rect` + 逐条 `draw_line` 是"每帧几千次绘制提交"。
# 需求（文档「十.4」）是"静态格子渲染成缓存纹理，只在格子集变化时重绘一次"。
# 本实现把「底板 + 逐格底色 + 网格线」画进一张**盘局部** `ImageTexture`：
#   · 生成时机：`ensure_static_cache()`（`_draw` 开头调用），仅当指纹/失效标志变了才重建；
#   · 绘制代价：每帧 1 次 `draw_texture`（与格数无关）；
#   · 盘局部 ⇒ 平移不重建、缩放（格宽变）才重建。
#
# 【无头降级】`DisplayServer.get_name() == "headless"`（没有渲染服务器，纹理永远不会被显示）
# 或纹理超预算时：**不分配纹理**，退回"每帧直绘"（`_paint_static_canvas`）——
# 不报错、动态层不受影响，并把原因写进 `static_cache_reason()` 供人/测试读取。

## 作废静态层缓存：下次 `ensure_static_cache()` 会重建。
## 调用时机：格子集 / 棋盘尺寸 / 格宽（缩放）/ 主题 / 显示开关变化时。
func invalidate_static_cache(reason: String = "") -> void:
	_static_dirty = true
	_static_invalidations += 1
	if not reason.is_empty():
		_static_invalidate_note = reason


## 确保静态层缓存可用。true = 纹理已就绪（`_draw` 走 `draw_texture`）；false = 应退回每帧直绘。
func ensure_static_cache() -> bool:
	if doc == null or doc.rows <= 0 or doc.cols <= 0:
		return false
	var key := _static_key()
	if not _static_dirty and key == _static_cache_key:
		return _static_cache != null
	# 需要（重）建：清旧纹理、记账，再按降级口径决定"真建"还是"直绘"。
	_static_dirty = false
	_static_cache_key = key
	_static_cache_builds += 1
	_static_cache = null
	var reason := _static_cache_block_reason()
	if not reason.is_empty():
		_static_degraded_reason = reason
		return false
	var img := _build_static_image()
	if img == null:
		_static_degraded_reason = "静态层图像构建失败（尺寸非法）"
		return false
	var tex := ImageTexture.create_from_image(img)
	if tex == null:
		_static_degraded_reason = "纹理创建失败（渲染后端不可用）"
		return false
	_static_degraded_reason = ""
	_static_cache = tex
	return true


## 缓存是否就绪（true ⇒ `_draw` 走 `draw_texture`）。
func static_cache_ready() -> bool:
	return _static_cache != null


## 是否处于降级态（不缓存、每帧直绘）。
func static_cache_degraded() -> bool:
	return not _static_degraded_reason.is_empty()


## 降级原因（人话；空 = 未降级）。
func static_cache_reason() -> String:
	return _static_degraded_reason


## （重）建次数 —— 可观察计数，供单测断言"失效后确实重建"（不依赖像素比对）。
func static_cache_builds() -> int:
	return _static_cache_builds


## 显式失效请求次数（`invalidate_static_cache()` 被调用的次数）。
func static_cache_invalidations() -> int:
	return _static_invalidations


## 降级直绘路径被执行的次数（无头下应 > 0：证明"降级被触发"而不是"什么都没画"）。
func static_cache_direct_draws() -> int:
	return _static_direct_draws


## 静止内容的指纹：变了就该重建。含棋盘形状 / 格宽 / 画布尺寸 / 网格策略 / 显雷开关 /
## 三集合内容 / 主题。
## 【为什么要"内容指纹"】编辑器里有些路径**直接**改 `doc.mines/obstacles/revealed`
##（不走画布的 `_apply_kind`），只靠显式失效会漏 ⇒ 指纹是兜底（同计数、不同内容也能发现）。
func _static_key() -> String:
	if doc == null:
		return ""
	return "%d,%d|%.4f|%.1f,%.1f|%d|%d|%d|%d|%d|%d|%s|%s" % [
		doc.cols, doc.rows, cell_px(), size.x, size.y,
		grid_line_step(), 1 if show_mines else 0,
		doc.mines.size(), doc.obstacles.size(), doc.revealed.size(), _doc_fingerprint(),
		ThemeManager.mode, ThemeManager.skin_id,
	]


## 三集合内容的轻量指纹（同计数但格子挪了也能发现）。O(格数) 整数运算，远低于一次绘制提交。
func _doc_fingerprint() -> int:
	var h := 0
	for p in doc.mines:
		h = (h * 31 + p.x * 73 + p.y) & 0x7fffffff
	for p in doc.obstacles:
		h = (h * 31 + p.x * 73 + p.y) & 0x7fffffff
	for p in doc.revealed:
		h = (h * 31 + p.x * 73 + p.y) & 0x7fffffff
	return h


## 该不该降级：返回空串 = 可以缓存；非空 = 降级原因（人话）。
func _static_cache_block_reason() -> String:
	if DisplayServer.get_name() == "headless":
		# 无头 = 没有渲染服务器：纹理永远不可能被显示 ⇒ 不分配（也不碰任何后端接口）。
		return "无头环境（无渲染服务器）：静态层不缓存、每帧直绘"
	var cp := cell_px()
	var w := int(ceil(float(doc.cols) * cp))
	var h := int(ceil(float(doc.rows) * cp))
	if w <= 0 or h <= 0:
		return "棋盘像素尺寸非法（%d×%d）" % [w, h]
	if w > STATIC_CACHE_MAX_EDGE or h > STATIC_CACHE_MAX_EDGE:
		return "静态层纹理单边超过 %d（%d×%d）：不缓存、每帧直绘" % [STATIC_CACHE_MAX_EDGE, w, h]
	if w * h > STATIC_CACHE_MAX_PIXELS:
		return "静态层纹理面积超过 %d 像素（%d×%d）：不缓存、每帧直绘" % [STATIC_CACHE_MAX_PIXELS, w, h]
	return ""


## 把静态层画进一张**盘局部**图像（坐标原点 = 棋盘左上角，单位 = 当前格宽下的像素）。
func _build_static_image() -> Image:
	var cp := cell_px()
	var w := int(ceil(float(doc.cols) * cp))
	var h := int(ceil(float(doc.rows) * cp))
	if w <= 0 or h <= 0:
		return null
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var base := ThemeManager.board_mat()
	img.fill(base)
	var ms := doc.mine_set() if show_mines else {}
	var ob := {}
	for p in doc.obstacles:
		ob[p] = true
	# 逐格底色（内缩 1px，与直绘路径的 `inner` 完全同口径）
	for y in doc.rows:
		var y0 := int(round(float(y) * cp))
		var y1 := int(round(float(y + 1) * cp))
		for x in doc.cols:
			var x0 := int(round(float(x) * cp))
			var x1 := int(round(float(x + 1) * cp))
			var inner := Rect2i(x0 + 1, y0 + 1, maxi(x1 - x0 - 2, 0), maxi(y1 - y0 - 2, 0))
			if inner.size.x <= 0 or inner.size.y <= 0:
				continue
			img.fill_rect(inner, _cell_fill_color(Vector2i(x, y), ms, ob))
	# 网格线：`Image.fill_rect` **不做混合**，故先把半透明线色与底板合成一次再写入
	#（合成口径显式写清，不用 `Color.blend` —— 其"谁压谁"容易读错）。
	var step := grid_line_step()
	if step > 0:
		var line_col := _over(ThemeManager.board_grid(), base)
		var vi := 0
		while vi <= doc.cols:
			img.fill_rect(Rect2i(clampi(int(round(float(vi) * cp)), 0, w - 1), 0, 1, h), line_col)
			vi += step
		var hi := 0
		while hi <= doc.rows:
			img.fill_rect(Rect2i(0, clampi(int(round(float(hi) * cp)), 0, h - 1), w, 1), line_col)
			hi += step
	return img


## 显式 source-over 合成（`fg` 压在 `bg` 上），直写公式避免读错 `Color.blend` 的方向。
static func _over(fg: Color, bg: Color) -> Color:
	var a := fg.a + bg.a * (1.0 - fg.a)
	if a <= 0.0:
		return Color(0, 0, 0, 0)
	return Color(
		(fg.r * fg.a + bg.r * bg.a * (1.0 - fg.a)) / a,
		(fg.g * fg.a + bg.g * bg.a * (1.0 - fg.a)) / a,
		(fg.b * fg.a + bg.b * bg.a * (1.0 - fg.a)) / a,
		a)
