# board_view.gd —— 棋盘渲染 + 拾取 + 键盘 + 涟漪动效 + scale-to-fit【plan1.1 §10.7.6】
# 渲染只 queue_redraw() 交给 Godot 调度，禁手写脏矩形。
# 判负引爆格高亮从 GameSession.exploded_pos 取；终局揭晓绘制雷位允许调
# get_mine_positions()（渲染，非判负逻辑；红线 2 的例外条款）。
# 全部色值经 ThemeManager；无 48px 硬编码（全文件跟随 cell_px）。
extends Control

## cell_px：scale-to-fit 动态格尺寸（§8.4.7 公式；24~48px）
var cell_px: int = 48
## 棋盘绘制原点（恒居中）
var board_origin: Vector2 = Vector2.ZERO
## 鼠标悬停格（-1,-1 = 无）
var hover_pos: Vector2i = Vector2i(-1, -1)

## 涟漪动效队列（§8.4.5）：{pos: Vector2i, t0: float（ msec ）， k: int 级联序号}
var _ripples: Array = []
var _ripple_window_start_ms: int = -1

## 提示高亮（一步直推）：结论格描边 + 依据格描边（推理文字见 HintPanel 浮动窗口）
var _hint_steps: Array = []
var _hint_until_ms: int = -1
const HINT_TTL_MS := 6000


func _ready() -> void:
	add_to_group("themed")
	ThemeManager.theme_changed.connect(queue_redraw)
	GameSession.session_started.connect(_on_session_started)
	if not GameSession.hint_ready.is_connected(_on_hint_ready):
		GameSession.hint_ready.connect(_on_hint_ready)
	# 绘画层（棋盘之上、HUD 之下）+ 底栏工具栏
	_drawing = load("res://ui/drawing_layer.tscn").instantiate()
	add_child(_drawing)
	var hud: Control = load("res://ui/hud.tscn").instantiate()
	add_child(hud)
	_toolbar = load("res://ui/drawing_toolbar.tscn").instantiate()
	add_child(_toolbar)
	_toolbar.setup(_drawing)
	_game_over = load("res://ui/game_over.tscn").instantiate()
	add_child(_game_over)
	# 提示浮动窗口（推理文字；可拖拽/缩放/调字体）
	_hint_panel = HintPanel.new()
	add_child(_hint_panel)
	# 绘画层引用交给 GameSession，供存档/恢复
	GameSession.drawing_layer = _drawing
	# 双时序兼容：_ready 里手动调一次（恢复路径时 session 先开好、场景后进来）
	_on_session_started()
	get_viewport().connect("size_changed", _layout)
	_layout()


var _game_over: Control
var _drawing: DrawingLayer
var _toolbar: Control
var _hint_panel: HintPanel


func _on_session_started() -> void:
	_connect_board()
	_ripples.clear()
	_ripple_window_start_ms = -1
	_clear_hint()
	_load_drawing()
	_layout()
	queue_redraw()


## 恢复对局时载入存档中的绘画；新对局则清空
func _load_drawing() -> void:
	if _drawing == null:
		return
	var pending: Dictionary = GameSession.pending_drawing
	if pending is Dictionary and not pending.is_empty():
		_drawing.load_save_data(pending)
	else:
		_drawing.clear_strokes()


# ============ 提示显示（一步直推；结论只读玩家视角，不读雷位） ============

func _on_hint_ready(steps: Array) -> void:
	_hint_steps = steps
	var now_ms := Time.get_ticks_msec()
	_hint_until_ms = now_ms + HINT_TTL_MS if not steps.is_empty() else -1
	if _hint_panel != null:
		_hint_panel.show_hint(steps)
	queue_redraw()


## 盘面一变（翻开/插旗）旧提示即失效，避免误导。
func _clear_hint() -> void:
	_hint_steps = []
	_hint_until_ms = -1
	if _hint_panel != null:
		_hint_panel.clear_hint()


## Board 是新实例，每次 start/restart/restore 都重连（§10.11-3）。
func _connect_board() -> void:
	if GameSession.board == null:
		return
	if not GameSession.board.cell_state_changed.is_connected(_on_cell_changed):
		GameSession.board.cell_state_changed.connect(_on_cell_changed)


func _on_cell_changed(pos: Vector2i) -> void:
	_clear_hint()  # 盘面变化 → 旧推理结论失效
	# 涟漪触发：任意格子 revealed 状态变更（含连锁翻开）
	if GameSession.board == null:
		return
	var cell := GameSession.board.grid.get_cell(pos)
	if cell != null and cell.state == Cell.State.REVEALED:
		if SettingsManager != null and SettingsManager.ripple_enabled:
			var now_ms := Time.get_ticks_msec()
			if now_ms - _ripple_window_start_ms > 400:
				_ripple_window_start_ms = now_ms
				_ripples.clear()  # 上一波动画窗口关闭，新窗口从 k=0 重新计
			_ripples.append({"pos": pos, "t0": now_ms, "k": _ripples.size()})
	queue_redraw()


func _layout() -> void:
	if GameSession.board == null or GameSession.board.grid == null:
		return
	var size := GameSession.board.grid.size()  # Vector2i(cols, rows)
	var cols: int = size.x
	var rows: int = size.y
	var vp := get_viewport_rect().size
	# 边距：左右 24、上 HUD 64 + 上边距 24、下边距 24 + 底栏 64（随窗口自适应，无 48px 上限）
	var avail_w: float = vp.x - 48.0
	var avail_h: float = vp.y - 64.0 - 64.0 - 48.0
	cell_px = maxi(floori(min(avail_w / float(cols), avail_h / float(rows))), 24)
	var board_w: float = float(cols) * cell_px
	var board_h: float = float(rows) * cell_px
	board_origin = Vector2((vp.x - board_w) * 0.5, 64.0 + (avail_h - board_h) * 0.5)
	queue_redraw()


func _process(_delta: float) -> void:
	var now_ms := Time.get_ticks_msec()
	var hint_expired := false
	if _hint_until_ms > 0 and now_ms >= _hint_until_ms:
		# 高亮描边到期只清高亮；推理文字窗口保留（盘面变化时才清）
		_hint_steps = []
		_hint_until_ms = -1
		hint_expired = true
	# 涟漪存在期间持续重绘；队列清空即停止（§8.4.5 性能条款）
	if _ripples.is_empty():
		if hint_expired:
			queue_redraw()
		return
	_ripples = _ripples.filter(func(rp): return now_ms - rp["t0"] < 400)
	if _ripples.is_empty():
		_ripple_window_start_ms = -1
	queue_redraw()


# ============ 渲染（§8.4.8 逐格绘制，全部色值经 ThemeManager） ============

func _draw() -> void:
	var session := GameSession
	if session.board == null or session.board.grid == null:
		return
	var board: Board = session.board
	var size := board.grid.size()
	var scale := float(cell_px) / 48.0
	var font := ThemeDB.fallback_font
	var endgame: bool = board.state != Board.GameState.PLAYING

	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var cell := board.grid.get_cell(pos)
			var rect := Rect2(board_origin + Vector2(c, r) * cell_px, Vector2(cell_px, cell_px))
			# 涟漪几何（§8.4.5）：中心格缩放弹跳 / 邻格向远离中心平移（直接改绘制矩形，免矩阵）
			var rrect: Rect2 = _ripple_rect_for(pos, rect)
			_draw_cell(pos, cell, rrect, scale, font, endgame)

	# 邻格颜色微闪（§8.4.5：深色 5% 提亮 / 亮色 5% 压暗）
	if not endgame:
		_draw_ripple_flashes()

	# 终局揭晓（非 PLAYING）：全部雷位画雷体 + 引爆格 danger 底
	if endgame:
		_draw_mines_reveal(board, scale)

	# 悬停反馈（§8.4.4；终局不响应）
	# hover_highlight 只决定"是否连带高亮 8 邻"；关闭时仍高亮鼠标所在格本身，否则悬停将毫无反馈
	if not endgame and hover_pos.x >= 0 and SettingsManager != null:
		_draw_hover_highlight(hover_pos, SettingsManager.hover_highlight)

	# 键盘光标（2px 描边框，accent alpha 0.65，与悬停可叠加）
	if not endgame and session.cursor.x >= 0 and SettingsManager != null and SettingsManager.keyboard_enabled:
		var crect := Rect2(board_origin + Vector2(session.cursor.x, session.cursor.y) * cell_px + Vector2(1, 1), Vector2(cell_px - 2, cell_px - 2))
		var col := ThemeManager.accent()
		col.a = 0.65
		draw_rect(crect, col, false, 2.0)

	if not endgame:
		_draw_hint(scale, font)


## 提示高亮：结论格 safe=绿描边 / mine=红描边；依据线索格 accent 细描边。
## 推理文字由 HintPanel 浮动窗口显示（可拖拽/缩放/调字体），不在此绘制。
func _draw_hint(scale: float, _font: Font) -> void:
	if _hint_steps.is_empty():
		return
	for s in _hint_steps:
		var step := s as ReasoningStep
		if step == null:
			continue
		var p: Vector2i = step.pos
		if not GameSession.board.grid.in_board(p):
			continue
		# 弱提示（对标 doc10 §3.2）：只画依据线索，不画结论格 —— 玩家自己推可推格
		if step.method != "weak":
			var rect := Rect2(board_origin + Vector2(p.x, p.y) * cell_px + Vector2(2, 2), Vector2(cell_px - 4, cell_px - 4))
			var col := ThemeManager.safe() if step.state == "safe" else ThemeManager.danger()
			draw_rect(rect, col, false, 3.0 * maxf(scale, 0.6))
		for src in step.sources:
			var sp: Vector2i = src
			if not GameSession.board.grid.in_board(sp):
				continue
			var srect := Rect2(board_origin + Vector2(sp.x, sp.y) * cell_px + Vector2(1, 1), Vector2(cell_px - 2, cell_px - 2))
			var scol := ThemeManager.accent()
			scol.a = 0.8
			draw_rect(srect, scol, false, 2.0)


func _draw_cell(pos: Vector2i, cell: Cell, rect: Rect2, scale: float, font: Font, endgame: bool) -> void:
	match cell.state:
		Cell.State.HIDDEN:
			draw_rect(rect, ThemeManager.cell_hidden())
			draw_rect(rect, ThemeManager.grid_line(), false, 1.0)
		Cell.State.FLAGGED:
			_draw_flag(rect, scale)
		Cell.State.QUESTION:
			draw_rect(rect, ThemeManager.cell_hidden())
			draw_rect(rect, ThemeManager.grid_line(), false, 1.0)
			_draw_question(rect, scale, font)
		Cell.State.REVEALED:
			draw_rect(rect, ThemeManager.cell_revealed())
			draw_rect(rect, ThemeManager.grid_line(), false, 1.0)
			_draw_clue_value(cell, rect, scale, font)


## 绘制翻开格的线索值（变体感知）：? 格 → "?"；HV 双值 → "A·B"；FR ∞ → "∞"；数字 1~12。
func _draw_clue_value(cell: Cell, rect: Rect2, scale: float, font: Font) -> void:
	# 终极模式星号格（对标 doc10 §2.4）：值对玩家隐藏，只画星号
	if cell.starred:
		var text := "*"
		var fsize := int(26.0 * maxf(scale, 0.6))
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize)
		draw_string(font,
			rect.position + Vector2((rect.size.x - tw.x) * 0.5, rect.size.y * 0.5 + tw.y * 0.34),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, ThemeManager.accent())
		return
	# ? 遮蔽格（interval 约束）
	if cell.is_hidden_clue():
		_draw_question(rect, scale, font)
		return
	# E 类线索混合：一格同时给出两个线索值 → 上下两行分绘，中线分隔
	if cell.value2 != null:
		var half_h: float = rect.size.y * 0.5
		_draw_single_clue(cell.value, Rect2(rect.position, Vector2(rect.size.x, half_h)), scale, font)
		_draw_single_clue(cell.value2, Rect2(rect.position + Vector2(0, half_h), Vector2(rect.size.x, half_h)), scale, font)
		var my: float = rect.position.y + half_h
		draw_line(Vector2(rect.position.x + 5.0 * scale, my), Vector2(rect.position.x + rect.size.x - 5.0 * scale, my), ThemeManager.grid_line(), 1.0)
		return
	_draw_single_clue(cell.value, rect, scale, font)


## 单个线索值文本绘制（居中于给定矩形；半格高度时自动缩小字号）。
func _draw_single_clue(v: Variant, rect: Rect2, scale: float, font: Font) -> void:
	var text := ""
	var col := ThemeManager.text()
	if v is Array:
		text = "%d·%d" % [int(v[0]), int(v[1])]  # HV 纵横分计 [正交, 对角]
	elif v is String:
		text = "∞" if v == "inf" else str(v)     # FR 首雷无雷哨兵
	elif v is int and v >= 0 and v <= 12:
		text = str(v)
		# number(n) 对 n<1 或 n>8 退化为主文本色，所以 0 自然用主文本色（可读但不抢眼）。
		col = ThemeManager.number(v)
	if text == "":
		return
	var fs2 := int(round(26.0 * scale))
	if rect.size.y < rect.size.x * 0.75:
		fs2 = int(round(16.0 * scale))           # 线索混合半格
	elif text.length() > 1:
		fs2 = int(round(20.0 * scale))           # 多字符（双值/∞）缩小字号
	var baseline: float = rect.size.y * 0.5 + fs2 * 0.35
	draw_string(font, rect.position + Vector2(0, baseline), text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, fs2, col)


## 居中「?」（QUESTION 标记态与 interval 遮蔽格共用，保证两处永远一致）。
## 与 _draw_single_clue 同口径：x 不手动偏移，交给 width=rect.size.x + CENTER 居中。
## 历史 bug：既手动偏移 -fs*0.3 又传 width+CENTER → 双重居中，问号右偏近半格
##（48px 格子、fs=20 时偏 18px）。
func _draw_question(rect: Rect2, scale: float, font: Font) -> void:
	var fs := int(round(20.0 * scale))
	draw_string(font, rect.position + Vector2(0, rect.size.y * 0.5 + fs * 0.35), "?", HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, fs, ThemeManager.text_secondary())


## §8.4.8 FLAGGED：HIDDEN 底 + 旗杆 draw_rect + 三角 draw_polygon（48px 基准坐标×scale）
func _draw_flag(rect: Rect2, scale: float) -> void:
	draw_rect(rect, ThemeManager.cell_hidden())
	draw_rect(rect, ThemeManager.grid_line(), false, 1.0)
	var x: float = rect.position.x
	var y: float = rect.position.y
	# 旗杆 Rect2(x+22, y+10, 2, 18)
	var pole := Rect2(x + 22.0 * scale, y + 10.0 * scale, 2.0 * scale, 18.0 * scale)
	draw_rect(pole, ThemeManager.text_secondary())
	# 三角 [(x+24,y+10),(x+24,y+22),(x+37,y+16)]
	var tri := PackedVector2Array([
		Vector2(x + 24.0 * scale, y + 10.0 * scale),
		Vector2(x + 24.0 * scale, y + 22.0 * scale),
		Vector2(x + 37.0 * scale, y + 16.0 * scale),
	])
	draw_polygon(tri, PackedColorArray([ThemeManager.danger()]))


## 终局揭晓：全部雷位画雷体（圆 + 4 刺线）；引爆格先画 danger 底。
func _draw_mines_reveal(board: Board, scale: float) -> void:
	var exploded: Vector2i = GameSession.exploded_pos
	var body_col := ThemeManager.mine_body()
	for m in board.get_mine_positions():
		var rect := Rect2(board_origin + Vector2(m.x, m.y) * cell_px, Vector2(cell_px, cell_px))
		if m == exploded:
			draw_rect(rect, ThemeManager.danger())
		var center := rect.position + rect.size * 0.5
		draw_circle(center, 11.0 * scale, body_col)
		var spike: float = 15.0 * scale
		draw_line(center + Vector2(0, 6.0 * scale), center + Vector2(0, 6.0 * scale + spike), body_col, 1.5 * scale)
		draw_line(center - Vector2(0, 6.0 * scale), center - Vector2(0, 6.0 * scale + spike), body_col, 1.5 * scale)
		draw_line(center + Vector2(6.0 * scale, 0), center + Vector2(6.0 * scale + spike, 0), body_col, 1.5 * scale)
		draw_line(center - Vector2(6.0 * scale, 0), center - Vector2(6.0 * scale + spike, 0), body_col, 1.5 * scale)


## §8.4.4 悬停高亮：中心格内陷（恒有，保证鼠标有落点反馈）
## + 8 邻柔光（仅 hover_highlight 开启时），不改变格子状态色
func _draw_hover_highlight(center_pos: Vector2i, with_neighbors: bool) -> void:
	var board: Board = GameSession.board
	if board == null:
		return
	# 中心格遮罩
	var crect := Rect2(board_origin + Vector2(center_pos.x, center_pos.y) * cell_px, Vector2(cell_px, cell_px))
	draw_rect(crect, ThemeManager.hover_center_overlay())
	if not with_neighbors:
		return
	# 周围 8 邻（按实际存在的邻格）
	for d in [Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1)]:
		var np: Vector2i = center_pos + d
		if board.grid.in_board(np):
			var nrect := Rect2(board_origin + Vector2(np.x, np.y) * cell_px, Vector2(cell_px, cell_px))
			draw_rect(nrect, ThemeManager.hover_neighbor_overlay())


# ============ 涟漪动效（§8.4.5：150ms 中心弹跳 / 200ms 邻格平移 / 50ms 级联 / ≤400ms） ============

## pos 参与活跃涟漪时返回调整后的绘制矩形（中心缩放 / 邻格位移），否则原样返回。
func _ripple_rect_for(pos: Vector2i, rect: Rect2) -> Rect2:
	if _ripples.is_empty():
		return rect
	var now_ms := Time.get_ticks_msec()
	for rp in _ripples:
		var t: float = (float(now_ms - rp["t0"]) - 50.0 * rp["k"]) / 1000.0
		if t < 0.0:
			continue
		var center: Vector2i = rp["pos"]
		if center == pos:
			# 中心格：缩放 1.0 → 1.15 → 1.0，150ms（矩形绕中心缩放）
			var tc: float = clampf(t / 0.15, 0.0, 1.0)
			var s: float = 1.0 + 0.15 * sin(PI * tc)
			var half := rect.size * 0.5 * s
			var cpos := rect.position + rect.size * 0.5
			return Rect2(cpos - half, half * 2.0)
		elif _is_8_neighbor(pos, center):
			# 邻格：向远离中心方向平移 3px（按格子尺寸缩放，200ms）
			var tn: float = clampf(t / 0.2, 0.0, 1.0)
			var amp: float = 3.0 * (float(cell_px) / 48.0) * sin(PI * tn)
			var dir := (Vector2(pos.x, pos.y) - Vector2(center.x, center.y)).normalized()
			if dir.length() < 0.5:
				dir = Vector2.ZERO
			return Rect2(rect.position + dir * amp, rect.size)
	return rect


func _is_8_neighbor(a: Vector2i, b: Vector2i) -> bool:
	var d: Vector2i = (a - b).abs()
	return (d.x <= 1 and d.y <= 1) and not (d.x == 0 and d.y == 0)


## 邻格颜色微闪：深色模式叠加 5% 提亮 / 亮色模式叠加 5% 压暗（§8.4.5）。
func _draw_ripple_flashes() -> void:
	if _ripples.is_empty():
		return
	var now_ms := Time.get_ticks_msec()
	var flash := Color(1, 1, 1, 0.05)
	if ThemeManager.mode == "light":
		flash = Color(0, 0, 0, 0.05)
	for rp in _ripples:
		var t: float = (float(now_ms - rp["t0"]) - 50.0 * rp["k"]) / 1000.0
		if t < 0.0 or t > 0.2:
			continue
		var center: Vector2i = rp["pos"]
		var fade: float = 1.0 - clampf(t / 0.2, 0.0, 1.0)
		var f := flash
		f.a *= fade
		for d in [Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1)]:
			var np: Vector2i = center + d
			if GameSession.board != null and GameSession.board.grid != null and GameSession.board.grid.in_board(np):
				var nrect := Rect2(board_origin + Vector2(np.x, np.y) * cell_px, Vector2(cell_px, cell_px))
				draw_rect(nrect, f)


# ============ 输入（§10.9；一切入口第一行检查 state == PLAYING） ============

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if GameSession.state != GameSession.State.PLAYING:
			return  # 终局冻结（重开/返回是 HUD/GameOver 层的例外按钮）
		var pos := _pick(event.position)
		if pos.x < 0:
			return
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			GameSession.reveal(pos)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			GameSession.toggle_flag(pos)
			accept_event()
	elif event is InputEventMouseMotion:
		if GameSession.state == GameSession.State.PLAYING:
			var pos := _pick(event.position)
			if pos != hover_pos:
				hover_pos = pos
				queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	if SettingsManager != null and not SettingsManager.keyboard_enabled:
		return
	if GameSession.state != GameSession.State.PLAYING:
		# R 重开是终局例外（HUD/GameOver 也有按钮；键盘通道同样允许）
		if event.keycode == KEY_R:
			GameSession.restart()
			accept_event()
		return
	# P 键切换绘画模式
	if event.keycode == KEY_P and not event.ctrl_pressed and not event.shift_pressed:
		_toggle_paint_mode()
		accept_event()
		return
	# 绘画模式：只响应绘画快捷键，忽略翻格/插旗/移动等游戏键
	if _drawing != null and _drawing.is_paint_mode():
		if _handle_paint_key(event):
			accept_event()
		return
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	var size := board.grid.size()
	var cur: Vector2i = GameSession.cursor
	var handled := true
	match event.keycode:
		KEY_R:
			GameSession.restart()
		KEY_F:
			GameSession.toggle_flag(cur)
		KEY_H:
			GameSession.request_hint()
		KEY_SPACE, KEY_ENTER:
			GameSession.reveal(cur)
		KEY_HOME:
			cur.x = 0
		KEY_END:
			cur.x = size.x - 1
		KEY_PAGEUP:
			cur.y = 0
		KEY_PAGEDOWN:
			cur.y = size.y - 1
		KEY_W, KEY_UP:
			cur.y = maxi(cur.y - 1, 0)
		KEY_S, KEY_DOWN:
			cur.y = mini(cur.y + 1, size.y - 1)
		KEY_A, KEY_LEFT:
			if cur.x == 0:
				# 回环：左边界 → 上一行右端
				if cur.y > 0:
					cur.y -= 1
					cur.x = size.x - 1
			else:
				cur.x -= 1
		KEY_D, KEY_RIGHT:
			if cur.x == size.x - 1:
				# 回环：右边界 → 下一行左端
				if cur.y < size.y - 1:
					cur.y += 1
					cur.x = 0
			else:
				cur.x += 1
		_:
			handled = false
	if handled:
		GameSession.cursor = cur
		queue_redraw()
		accept_event()


# ============ 绘画模式（P 键 / 快捷键） ============

func _toggle_paint_mode() -> void:
	if _drawing != null:
		_drawing.toggle_paint_mode()
		if _toolbar != null:
			_toolbar.refresh()


## 绘画模式下的快捷键：ESC 退出 / E 橡皮 / C 清空 / 1~7 选色 / [ ] 粗细 / Ctrl+Z·Y 撤销重做
func _handle_paint_key(event: InputEventKey) -> bool:
	if event.ctrl_pressed:
		if event.keycode == KEY_Z:
			if event.shift_pressed:
				_drawing.redo()
			else:
				_drawing.undo()
			return true
		if event.keycode == KEY_Y:
			_drawing.redo()
			return true
		return false
	match event.keycode:
		KEY_ESCAPE:
			_drawing.set_paint_mode(false)
			if _toolbar != null:
				_toolbar.refresh()
			return true
		KEY_E:
			_drawing.toggle_eraser()
			return true
		KEY_C:
			_drawing.clear_all()
			return true
		KEY_1:
			_drawing.set_color(0)
			return true
		KEY_2:
			_drawing.set_color(1)
			return true
		KEY_3:
			_drawing.set_color(2)
			return true
		KEY_4:
			_drawing.set_color(3)
			return true
		KEY_5:
			_drawing.set_color(4)
			return true
		KEY_6:
			_drawing.set_color(5)
			return true
		KEY_7:
			_drawing.set_color(6)
			return true
		KEY_BRACKETLEFT:
			_drawing.cycle_size(-1)
			return true
		KEY_BRACKETRIGHT:
			_drawing.cycle_size(1)
			return true
	return false


func _pick(local_pos: Vector2) -> Vector2i:
	if cell_px <= 0:
		return Vector2i(-1, -1)
	var rel := local_pos - board_origin
	var c := floori(rel.x / float(cell_px))
	var r := floori(rel.y / float(cell_px))
	if GameSession.board == null or GameSession.board.grid == null:
		return Vector2i(-1, -1)
	var size := GameSession.board.grid.size()
	if c < 0 or c >= size.x or r < 0 or r >= size.y:
		return Vector2i(-1, -1)
	return Vector2i(c, r)
