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

## 开格波浪参数（§8.4.5；0 间隙棋盘：波浪的本质是**相位差**，不是位移）。
##   WS 每环延迟秒 · WD 单格时长秒 · GLOW 网格线高亮上限 · WP 颜色脉冲权重
##   SHRINK 填充收缩幅度 · COVER 波及范围比例 · MAX_RINGS 扩散层数上限
const WAVE_WS := 0.040        # 每环延迟（秒）：环 0/1 同时开始，环 2 起逐环错开
const WAVE_WD := 0.30         # 单格时长（秒）：waveE = sin(PI*t/WD)，唯一能精确回到 0
const WAVE_GLOW := 0.85       # 网格线混向高亮色的强度上限（本方案主通道）
const WAVE_WP := 0.75         # 颜色脉冲权重：峰值 alpha = WP * WAVE_PULSE_MAX
const WAVE_SHRINK := 0.04     # 填充原地收缩幅度（0 间隙下禁位移/放大）
const WAVE_COVER := 0.24      # 波及格数上限 = 总格数 × COVER（连续参数，跨环按 frac 衰减）
const WAVE_MAX_RINGS := 4     # 扩散层数上限（安全 + 收尾时长可控）
const WAVE_PULSE_MAX := 0.55  # 颜色脉冲相对 WP 的系数

# 用 preload 而非全局类名：新增脚本的全局类缓存未必在加载本场景前刷新，
# 直接用 `RippleRings` 会解析失败（单元测试首跑已复现）。纯静态方法，preload 等价。
const RIPPLE_RINGS := preload("res://core/ripple_rings.gd")

## 开格波浪：同一时间最多一条（新波浪覆盖旧波浪，天然防叠加）。
## 每条记录 = { pos 环0起点, t0 触发时刻ms, ring_of{格->环}, amp_of{格->振幅},
##              total_rings 最后一环, ring_sizes 各环格数, cells / target 供渐隐校验 }
var _ripples: Array = []
## 泛洪批次识别（规范硬规则一：只有 0 格泛洪引发的联动才播波浪）。
## 一次同步泛洪会连发多个 cell_state_changed，单格翻开只发一个；故先攒本帧「唯一格集合」，
## call_deferred 到同步 emit 全部结束后再结算——此时才能判定是单格还是联动。
var _pending_batch: Array = []
var _pending_seen: Dictionary = {}
var _batch_scheduled := false
## 波浪逐帧缓存（Vector2i -> {"s": 填充缩放, "g": 波浪强度 0..1}）。
## 原实现对每个格子 O(1) 扫描整个涟漪队列（连锁翻开时可达数十条），
## 大盘下变成 O(格子数 × 涟漪数)/帧。改为每帧只算一次几何，绘制时查表。
var _ripple_cache: Dictionary = {}
var _ripple_cache_ms: int = -1

## 提示高亮（一步直推）：结论格描边 + 依据格描边（推理文字见 HintPanel 浮动窗口）
var _hint_steps: Array = []
var _hint_until_ms: int = -1
const HINT_TTL_MS := 6000

## 无猜模式「猜测被拒」反馈：以前 GameSession 发了 guess_rejected 但没有任何订阅者，
## 玩家点下去只有一声音效、格子纹丝不动，看起来就像卡死。现给出视觉反馈 + 节流文案。
var _reject_pos: Vector2i = Vector2i(-1, -1)
var _reject_until_ms: int = -1
var _reject_toast_ms: int = -100000
const REJECT_FLASH_MS := 550
const REJECT_TOAST_THROTTLE_MS := 3000


func _ready() -> void:
	add_to_group("themed")
	ThemeManager.theme_changed.connect(queue_redraw)
	GameSession.session_started.connect(_on_session_started)
	if not GameSession.hint_ready.is_connected(_on_hint_ready):
		GameSession.hint_ready.connect(_on_hint_ready)
	if not GameSession.guess_rejected.is_connected(_on_guess_rejected):
		GameSession.guess_rejected.connect(_on_guess_rejected)
	# 鼠标移出棋盘：不再有 MouseMotion 事件，悬停高亮会永远定格在最后一格
	mouse_exited.connect(_on_mouse_exited)
	# 绘画层（棋盘之上、HUD 之下）+ 底栏工具栏
	_drawing = load("res://ui/drawing_layer.tscn").instantiate()
	add_child(_drawing)
	# 笔迹改用棋盘坐标存储：窗口缩放 / 换分辨率读档时笔记自动跟着格子走。
	# 闭包读的是当前字段值，故 _layout() 改变 cell_px / board_origin 后无需重新注入。
	_drawing.set_board_transform(
			func(p: Vector2): return board_origin + p * cell_px,
			func(p: Vector2): return (p - board_origin) / float(maxi(cell_px, 1)))
	var hud: Control = load("res://ui/hud.tscn").instantiate()
	add_child(hud)
	_toolbar = load("res://ui/drawing_toolbar.tscn").instantiate()
	add_child(_toolbar)
	_toolbar.setup(_drawing)
	_game_over = load("res://ui/game_over.tscn").instantiate()
	add_child(_game_over)
	_pause_menu = load("res://ui/pause_menu.tscn").instantiate()
	add_child(_pause_menu)
	_pause_menu.hide()  # Window 默认 visible=true，不显式隐藏会一进局就盖住棋盘
	# 提示浮动窗口（推理文字；可拖拽/缩放/调字体）
	_hint_panel = HintPanel.new()
	add_child(_hint_panel)
	# 绘画数据采集回调交给 GameSession（依赖倒置：autoload 不持有 UI 节点类型）。
	# 闭包读 board_view 自己的 _drawing 字段，取实时值；绘画层仅 _ready 创建一次，无需重复注册。
	GameSession.set_drawing_provider(func(): return _drawing.get_save_data())
	# v3.2/v3.3 存档内容自动保存：一笔画完/擦除/清空（changed）就落盘——
	# ① 写入按关草稿库（通关重进草稿仍在；清空绘画 = 删除草稿文件）；
	# ② 触发对局自动存档（走 1s 防抖）。关闭「绘画草稿存入存档」时两者都不触发。
	_drawing.changed.connect(func():
		if SettingsManager.drawing_in_save and GameSession.level_path != "":
			SaveCoordinator.save_drawing(GameSession.level_path, _drawing.get_save_data())
			GameSession.request_autosave())
	# 双时序兼容：_ready 里手动调一次（恢复路径时 session 先开好、场景后进来）
	_on_session_started()


## 离开场景时注销绘画采集回调：
## autoload（GameSession）生命周期长于本场景，不注销会留下悬空的 provider 闭包，
## 之后的自动存档会在引擎层报错（见 GameSession._get_drawing 的同名注释）。
func _exit_tree() -> void:
	GameSession.set_drawing_provider(Callable())
	get_viewport().connect("size_changed", _layout)
	_layout()


var _game_over: Control
var _drawing: DrawingLayer
var _toolbar: Control
var _hint_panel: HintPanel
var _pause_menu: PopupPanel


func _on_session_started() -> void:
	_connect_board()
	_ripples.clear()
	_pending_batch.clear()
	_pending_seen.clear()
	_batch_scheduled = false
	_ripple_cache.clear()
	_ripple_cache_ms = -1
	_clear_hint()
	_clear_reject()
	_load_drawing()
	_layout()
	queue_redraw()


## 恢复对局时载入存档中的绘画；新对局则清空
func _load_drawing() -> void:
	if _drawing == null:
		return
	# 用户关闭「绘画草稿存入存档」→ 恢复也不还原草稿（与新存档不带 drawing 字段一致）
	if SettingsManager != null and not SettingsManager.drawing_in_save:
		_drawing.clear_strokes()
		return
	var pending: Dictionary = GameSession.pending_drawing
	if pending is Dictionary and not pending.is_empty():
		_drawing.load_save_data(pending)
		# 旧版（v1 屏幕坐标）笔迹无法对齐棋盘 → 已丢弃，必须告知，不能静默消失
		if _drawing.legacy_discarded():
			UiToast.popup(self, "旧版绘画笔记无法对齐棋盘已清空；新笔记会跟随棋盘缩放")
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
	# 波浪触发：只认「0 格泛洪引发的联动」（规范硬规则一），单格翻开不播。
	# 判定方案：一次同步泛洪会连发 N 个 cell_state_changed，单格翻开只发 1 个 →
	# 按「本帧唯一格数」判定即可，无需改动 core/board.gd（保持最小改动、不碰核心）。
	if GameSession.board != null and GameSession.board.grid != null:
		var cell := GameSession.board.grid.get_cell(pos)
		if cell != null and cell.state == Cell.State.REVEALED:
			# 总闸（翻开动效）关闭时连批次都不登记，逻辑上不可能产生波浪/单格 pop。
			if _reveal_effects_enabled():
				_queue_reveal_batch(pos)
	queue_redraw()


## 把一个「已翻开」格登记进本帧泛洪批次（去重）。首个登记者负责安排延迟结算。
func _queue_reveal_batch(pos: Vector2i) -> void:
	if _pending_seen.has(pos):
		return
	# 终极模式 _star_new_revealed 会对同一格重复 emit；去重后单格翻开仍只算 1 → 不会误判泛洪。
	_pending_seen[pos] = true
	_pending_batch.append(pos)
	if not _batch_scheduled:
		_batch_scheduled = true
		call_deferred("_settle_reveal_batch")


## 同步泛洪全部 emit 结束后结算：唯一格数 >= 2 才算联动 → 以首个格为环 0 起点播波浪。
## 单格（数字格/雷格）翻开时唯一格数 = 1 → 不产生波浪。
func _settle_reveal_batch() -> void:
	_batch_scheduled = false
	var batch := _pending_batch
	_pending_batch = []
	_pending_seen = {}
	if batch.size() < 2:
		return
	_start_wave(batch[0])


## 无猜-专家档：翻开请求被拒绝（该格无法纯逻辑推出）。
## 必须给出可见反馈——否则玩家会认为点击无响应/游戏卡死。
func _on_guess_rejected(pos: Vector2i) -> void:
	_reject_pos = pos
	var now_ms := Time.get_ticks_msec()
	_reject_until_ms = now_ms + REJECT_FLASH_MS
	_request_frames()
	if now_ms - _reject_toast_ms > REJECT_TOAST_THROTTLE_MS:
		_reject_toast_ms = now_ms
		UiToast.popup(self, "这一格无法纯逻辑推出（无猜模式不允许猜测）")
	queue_redraw()


func _clear_reject() -> void:
	_reject_pos = Vector2i(-1, -1)
	_reject_until_ms = -1


func _on_mouse_exited() -> void:
	# 右键拖动插旗中移出控件：释放事件收不到（gui_input 只在控件内触发）→ 在此复位，
	# 否则 _flag_dragging 残留到下次右键按下才被重置（拖出再拖入会误插旗）
	_flag_dragging = false
	_flag_drag_last = Vector2i(-1, -1)
	if hover_pos.x < 0:
		return
	hover_pos = Vector2i(-1, -1)
	queue_redraw()


func _layout() -> void:
	if GameSession.board == null or GameSession.board.grid == null:
		return
	# `size`/`scale` 与 Control 自身属性同名（遮蔽告警）——局部只读使用，注解表达有意
	@warning_ignore("shadowed_variable_base_class")
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
	var dirty := false
	# 总开关关闭：立刻丢弃在途波浪与缓存 → 下一次重绘即静止态（无收缩、无高亮残留）。
	if not _reveal_effects_enabled() and not _ripples.is_empty():
		_clear_wave_state()
		dirty = true
	if _hint_until_ms > 0 and now_ms >= _hint_until_ms:
		# 高亮描边到期只清高亮；推理文字窗口保留（盘面变化时才清）
		_hint_steps = []
		_hint_until_ms = -1
		dirty = true
	if _reject_until_ms > 0 and now_ms >= _reject_until_ms:
		_reject_pos = Vector2i(-1, -1)
		_reject_until_ms = -1
		dirty = true
	# 波浪存在期间持续重绘；队列清空即停止（§8.4.5 性能条款）
	if not _ripples.is_empty():
		_cull_waves(now_ms)
		_ripple_cache_ms = -1  # 每帧时钟推进 → 缓存作废，绘制时按当前 ms 重算
		dirty = true
	if dirty:
		queue_redraw()
	# 无动画时彻底关掉逐帧回调：静态棋盘不需要每帧醒来
	if _ripples.is_empty() and _hint_until_ms < 0 and _reject_until_ms < 0:
		set_process(false)


## 有动画要做时唤醒逐帧回调（由波浪/提示/拒绝反馈各自调用）。
func _request_frames() -> void:
	if not is_processing():
		set_process(true)


## 淘汰已结束（超过总时长）的波浪。返回是否发生了变化。
## 抽成带参函数：测试可注入时钟验证「结束后精确回到静止态」，不依赖真实时间。
func _cull_waves(now_ms: int) -> bool:
	if _ripples.is_empty():
		return false
	var before := _ripples.size()
	_ripples = _ripples.filter(func(rp): return float(now_ms) - float(rp["t0"]) < float(rp["total_ms"]))
	if _ripples.size() == before:
		return false
	if _ripples.is_empty():
		# 波浪结束：必须清缓存，否则绘制层会残留高亮（收尾无残留是硬约束）
		_ripple_cache.clear()
	return true


# ============ 渲染（§8.4.8 逐格绘制，全部色值经 ThemeManager） ============

func _draw() -> void:
	var session := GameSession
	if session.board == null or session.board.grid == null:
		return
	var board: Board = session.board
	@warning_ignore("shadowed_variable_base_class")
	var size := board.grid.size()
	@warning_ignore("shadowed_variable_base_class")
	var scale := float(cell_px) / 48.0
	var font := ThemeDB.fallback_font
	var endgame: bool = board.state != Board.GameState.PLAYING
	# 总开关状态：关闭时本帧走静止绘制路径（无收缩/无脉冲/线色原值）。
	# 这里再兜底清一次在途波浪，保证任何重绘入口（窗口缩放/主题切换/测试直调）都无残留。
	var effects_on := _reveal_effects_enabled()
	if not effects_on and not _ripples.is_empty():
		_clear_wave_state()

	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var cell := board.grid.get_cell(pos)
			# 异形拓扑（AdjacencyGrid）洞格返回 null（口径与 save/hud/stats 的 all_positions 对齐）：
			# 此前直接 _draw_cell(null) 空引用中止 _draw → 棋盘渲染整体失效。
			if cell == null:
				continue
			var rect := Rect2(board_origin + Vector2(c, r) * cell_px, Vector2(cell_px, cell_px))
			# 波浪几何（§8.4.5）：受波及格原地收缩（0 间隙禁位移/放大；直接改绘制矩形，免矩阵）
			var rrect: Rect2 = _ripple_rect_for(pos, rect) if effects_on else rect
			_draw_cell(pos, cell, rrect, scale, font, endgame)

	# 波浪颜色脉冲（0 间隙方案：位移/放大被禁 → 颜色通道增强）
	if not endgame and effects_on:
		_draw_wave_color_pulse()

	# 网格线独立绘制遍（本方案主通道）：必须晚于填充与脉冲，且几何取自**原格矩形**——
	# 填充收缩时线不动，「网格永远笔直」成为结构性保证。
	_draw_grid_lines()

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
		_draw_reject()


## 无猜模式「猜测被拒」反馈：该格画一圈危险色描边，闪烁两下后淡出。
func _draw_reject() -> void:
	if _reject_pos.x < 0 or GameSession.board == null or GameSession.board.grid == null:
		return
	if not GameSession.board.grid.in_board(_reject_pos):
		return
	var remain: float = float(_reject_until_ms - Time.get_ticks_msec()) / float(REJECT_FLASH_MS)
	if remain <= 0.0:
		return
	var rect := Rect2(board_origin + Vector2(_reject_pos.x, _reject_pos.y) * cell_px + Vector2(2, 2),
			Vector2(cell_px - 4, cell_px - 4))
	var col := ThemeManager.danger()
	col.a = clampf(abs(sin((1.0 - remain) * TAU * 2.0)), 0.25, 1.0) * clampf(remain, 0.0, 1.0)
	draw_rect(rect, col, false, 3.0)


## 提示高亮：结论格 safe=绿描边 / mine=红描边；依据线索格 accent 细描边。
## 推理文字由 HintPanel 浮动窗口显示（可拖拽/缩放/调字体），不在此绘制。
@warning_ignore("shadowed_variable_base_class")
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


@warning_ignore("shadowed_variable_base_class")
@warning_ignore("unused_parameter")
func _draw_cell(pos: Vector2i, cell: Cell, rect: Rect2, scale: float, font: Font, endgame: bool) -> void:
	match cell.state:
		Cell.State.HIDDEN:
			draw_rect(rect, ThemeManager.cell_hidden())
		Cell.State.FLAGGED:
			_draw_flag(rect, scale)
		Cell.State.QUESTION:
			draw_rect(rect, ThemeManager.cell_hidden())
			_draw_question(rect, scale, font)
		Cell.State.REVEALED:
			draw_rect(rect, ThemeManager.cell_revealed())
			_draw_clue_value(cell, rect, scale, font)


## 绘制翻开格的线索值（变体感知）：? 格 → "?"；HV 双值 → "A·B"；FR ∞ → "∞"；数字 0+（含 0 与大值，见 _draw_single_clue）。
@warning_ignore("shadowed_variable_base_class")
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
@warning_ignore("shadowed_variable_base_class")
func _draw_single_clue(v: Variant, rect: Rect2, scale: float, font: Font) -> void:
	var text := ""
	var col := ThemeManager.text()
	if v is Array:
		# HV 纵横分计 [正交, 对角]。防御：长度不足 2 时退化为单值，避免越界（mod 规则可能返回畸形）。
		if (v as Array).size() >= 2:
			text = "%d·%d" % [int(v[0]), int(v[1])]
		else:
			text = str(v)
	elif v is String:
		text = "∞" if v == "inf" else str(v)     # FR 首雷无雷哨兵
	elif v is int and v >= 0:
		text = str(v)
		# number(n) 对 n<1 或 n>8 退化为主文本色，所以 0 与大值（异形拓扑 dist_sum / mod 规则）
		# 都用主文本色（可读但不抢眼），不再因 v <= 12 硬上限而漏画（那会是又一种「空白格」）。
		col = ThemeManager.number(v)
	if text == "":
		return
	var fs2 := int(round(26.0 * scale))
	if rect.size.y < rect.size.x * 0.75:
		fs2 = int(round(16.0 * scale))           # 线索混合半格
	elif text.length() > 1:
		fs2 = int(round(20.0 * scale))           # 多字符（双值/∞/大数）缩小字号
	var baseline: float = rect.size.y * 0.5 + fs2 * 0.35
	draw_string(font, rect.position + Vector2(0, baseline), text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, fs2, col)


## 居中「?」（QUESTION 标记态与 interval 遮蔽格共用，保证两处永远一致）。
## 与 _draw_single_clue 同口径：x 不手动偏移，交给 width=rect.size.x + CENTER 居中。
## 历史 bug：既手动偏移 -fs*0.3 又传 width+CENTER → 双重居中，问号右偏近半格
##（48px 格子、fs=20 时偏 18px）。
@warning_ignore("shadowed_variable_base_class")
func _draw_question(rect: Rect2, scale: float, font: Font) -> void:
	var fs := int(round(20.0 * scale))
	draw_string(font, rect.position + Vector2(0, rect.size.y * 0.5 + fs * 0.35), "?", HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, fs, ThemeManager.text_secondary())


## §8.4.8 FLAGGED：HIDDEN 底 + 旗杆 draw_rect + 三角 draw_polygon（48px 基准坐标×scale）
@warning_ignore("shadowed_variable_base_class")
func _draw_flag(rect: Rect2, scale: float) -> void:
	draw_rect(rect, ThemeManager.cell_hidden())
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
@warning_ignore("shadowed_variable_base_class")
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


# ============ 翻开动效开关（总闸 + 波浪细项） ============

## 翻开动效总闸（波浪 + 后续单格 pop）判定：唯一读点，后续单格 pop 复用本函数。
## 唯一开关即 SettingsManager.ripple_enabled（语义已扩展为总闸，界面标签「翻开动效（波浪 / 单格）」）。
## 读取刻意用 get_node_or_null 而非直接引用 autoload 名 `SettingsManager`：
## headless / 单测环境若未注册该 autoload，直接引用会在脚本解析期就报错；
## 这里把「设置系统缺失」一律按默认（开）处理，绝不抛错。
func _reveal_effects_enabled() -> bool:
	var sm: Node = get_node_or_null("/root/SettingsManager")
	if sm == null:
		return true
	var v: Variant = sm.get("ripple_enabled")
	return bool(v) if v is bool else true


## 丢弃全部波浪与几何缓存（新对局 / 关掉总开关时复用）。
## 缓存必须同步清空——否则绘制层会残留收缩与线色高亮（收尾无残留是硬约束）。
func _clear_wave_state() -> void:
	_ripples.clear()
	_ripple_cache.clear()
	_ripple_cache_ms = -1


# ============ 开格波浪（§8.4.5 重写：图距离分环 + 相位差；0 间隙只走收缩/颜色通道） ============

## 以 start 为环 0 起点构建一条波浪：RippleRings 按图距离分环 → 逐环延迟 → cover 渐隐。
## 环内顺序不影响观感（同环延迟相同）；0 间隙下禁用位移与放大。
func _start_wave(start: Vector2i) -> void:
	# 双保险：即便调用方（如 _settle_reveal_batch）没拦，关闭时也绝不建立波浪。
	if not _reveal_effects_enabled():
		return
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	var board_size: Vector2i = board.grid.size()
	# 拓扑无关：邻接关系由 grid 提供（矩形 8 邻 / 异形邻接表皆可）。
	var rings: Array = RIPPLE_RINGS.build(start, board_size, board.grid.get_neighbors, WAVE_MAX_RINGS)
	if rings.is_empty():
		return
	var total_cells := 0
	for ring in rings:
		total_cells += (ring as Array).size()
	# cover 是连续参数：波及格数达到 总格数 × COVER 即停；跨过目标的那一环按
	# frac = (target - 已累计) / 环内格数 衰减振幅，避免「多一格就整环全亮」的阶跃。
	var target: int = maxi(int(floor(float(total_cells) * WAVE_COVER)), 1)
	var ring_of := {}
	var amp_of := {}
	var ring_sizes: Array = []
	var cum := 0
	var last_ring := 0
	for i in rings.size():
		var ring: Array = rings[i]
		var n: int = ring.size()
		if n <= 0:
			continue
		var frac := 1.0
		if cum + n > target:
			frac = clampf(float(target - cum) / float(n), 0.0, 1.0)
		if frac > 0.0:
			for p in ring:
				ring_of[p] = i
				amp_of[p] = frac
			ring_sizes.append(n)
			last_ring = i
		cum += n
		if cum >= target:
			break
	if ring_of.is_empty():
		return
	# 新波浪覆盖旧波浪：同一时间只有一条，天然满足「泛洪进行中不叠加新波浪」。
	_ripples.clear()
	_ripples.append({
		"pos": start,
		"t0": float(Time.get_ticks_msec()),
		"ring_of": ring_of,
		"amp_of": amp_of,
		"total_rings": last_ring,
		"ring_sizes": ring_sizes,
		"cells": ring_of.size(),
		"target": target,
		# 总时长 = 最后一环的起始延迟 + 单格时长（_process 依此淘汰，保证结束后无残留）
		"total_ms": (RIPPLE_RINGS.delay_of(last_ring, WAVE_WS) + WAVE_WD) * 1000.0,
	})
	_ripple_cache_ms = -1
	_request_frames()


## 波浪高亮色（从主题派生，禁止硬编码 RGB）：以翻开底色为底向主题强调色提亮。
## 深浅两种模式下都明显「比网格线亮」，且随主题/皮肤切换自动跟随。
func _wave_glow_color() -> Color:
	var c: Color = ThemeManager.cell_revealed().lerp(ThemeManager.accent(), 0.7)
	c.a = 1.0
	return c


## pos 处于活跃波浪时返回「原地收缩」后的绘制矩形；否则原样返回。
## 几何每帧统一算一次（_rebuild_ripple_cache），此处只查表——避免 O(格子数 × 涟漪数)。
func _ripple_rect_for(pos: Vector2i, rect: Rect2) -> Rect2:
	if _ripples.is_empty():
		return rect
	if _ripple_cache_ms != Time.get_ticks_msec():
		_rebuild_ripple_cache()
	var e: Dictionary = _ripple_cache.get(pos, {})
	if e.is_empty():
		return rect
	# 0 间隙棋盘禁位移与放大（会压到邻格）：只做绕中心的原地收缩。
	var half: Vector2 = rect.size * 0.5 * float(e["s"])
	var cpos: Vector2 = rect.position + rect.size * 0.5
	return Rect2(cpos - half, half * 2.0)


## 重算波浪几何/强度缓存。at_ms 仅供测试注入时钟（<= 0 → 用真实时钟）。
## 时间轴：t = (now - t0)/1000 - delay_of(环)，waveE = sin(PI*clamp(t/WD,0,1))*振幅。
## waveE 是唯一能精确回到 0 的曲线 → 动画收尾绝不残留（s 回 1.0、线色回原值）。
func _rebuild_ripple_cache(at_ms: int = -1) -> void:
	_ripple_cache.clear()
	_ripple_cache_ms = at_ms if at_ms > 0 else Time.get_ticks_msec()
	if _ripples.is_empty():
		return
	var now_ms := _ripple_cache_ms
	for rp in _ripples:
		var t0: float = float(rp["t0"])
		var ring_of: Dictionary = rp["ring_of"]
		var amp_of: Dictionary = rp["amp_of"]
		for pos in ring_of:
			var ring: int = int(ring_of[pos])
			var t: float = float(now_ms - t0) / 1000.0 - RIPPLE_RINGS.delay_of(ring, WAVE_WS)
			var e: float = sin(PI * clampf(t / WAVE_WD, 0.0, 1.0)) * float(amp_of.get(pos, 1.0))
			if e <= 0.0:
				continue  # t<=0（未开始）或 t>=WD（已结束）→ 不入缓存 = 精确静止态
			if _ripple_cache.has(pos):
				continue  # 命中语义：首条影响该格的波浪决定其形变
			_ripple_cache[pos] = {"s": 1.0 - WAVE_SHRINK * e, "g": e}


## 波浪颜色脉冲：受波及格按 WP * 0.55 * waveE 叠加高亮色（峰值约 0.41，双主题可见）。
func _draw_wave_color_pulse() -> void:
	if _ripples.is_empty() or not _reveal_effects_enabled():
		return
	if _ripple_cache_ms != Time.get_ticks_msec():
		_rebuild_ripple_cache()
	var glow := _wave_glow_color()
	for pos in _ripple_cache:
		var g: float = float(_ripple_cache[pos]["g"])
		var a: float = WAVE_WP * WAVE_PULSE_MAX * g
		if a <= 0.0:
			continue
		var col := glow
		col.a = a
		draw_rect(Rect2(board_origin + Vector2(pos.x, pos.y) * cell_px, Vector2(cell_px, cell_px)), col)


## 网格线独立绘制遍（0 间隙方案的主通道）。
## 几何永远取自**原格矩形**，填充即使在收缩，线层也不动 → 线永远笔直。
## 受波及格描边颜色按 glow*waveE 混向高亮色；waveE=0 时精确回到 grid_line 原色（无残留）。
func _draw_grid_lines() -> void:
	if GameSession.board == null or GameSession.board.grid == null:
		return
	var board: Board = GameSession.board
	var board_size: Vector2i = board.grid.size()
	var line := ThemeManager.grid_line()
	var glow := _wave_glow_color()
	var has_wave := not _ripples.is_empty() and _reveal_effects_enabled()
	if has_wave and _ripple_cache_ms != Time.get_ticks_msec():
		_rebuild_ripple_cache()
	for r in board_size.y:
		for c in board_size.x:
			var pos := Vector2i(c, r)
			if board.grid.get_cell(pos) == null:
				continue  # 异形拓扑洞格（与填充遍同口径）
			var rect := Rect2(board_origin + Vector2(c, r) * cell_px, Vector2(cell_px, cell_px))
			var col := line
			if has_wave:
				var e: Dictionary = _ripple_cache.get(pos, {})
				if not e.is_empty():
					col = line.lerp(glow, WAVE_GLOW * float(e["g"]))
			draw_rect(rect, col, false, 1.0)


# ============ 输入（§10.9；一切入口第一行检查 state == PLAYING） ============

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if GameSession.state != GameSession.State.PLAYING:
			return  # 终局冻结（重开/返回是 HUD/GameOver 层的例外按钮）
		var pos := _pick(event.position)
		if pos.x < 0:
			return
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			# 左键点已翻开的数字格 = 一键展开（chord）；点未翻开格 = 正常翻开
			if _quick_actions_enabled() and _is_revealed(pos):
				GameSession.chord(pos)
			else:
				GameSession.reveal(pos)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed:
			if _quick_actions_enabled():
				GameSession.chord(pos)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			GameSession.toggle_flag(pos)
			# 按住右键拖动 = 连续插旗（与 chord 同源的 QoL，市面标配）
			if _quick_actions_enabled():
				_flag_dragging = true
				_flag_drag_last = pos
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed:
			_flag_dragging = false
			_flag_drag_last = Vector2i(-1, -1)
			accept_event()
	elif event is InputEventMouseMotion:
		if GameSession.state == GameSession.State.PLAYING:
			var pos := _pick(event.position)
			if _flag_dragging and (event.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
				# 拖动只「插」不「取消」：每进入一个新格补一面旗，
				# 避免把已插好的旗拖没了（拖动中不做 toggle 循环）
				if pos.x >= 0 and pos != _flag_drag_last:
					_flag_drag_last = pos
					_flag_if_hidden(pos)
			if pos != hover_pos:
				hover_pos = pos
				queue_redraw()


## 最上层的可见弹出层（设置弹窗 / 确认框 / 暂停面板）；没有则返回 null。
## ★ 历史 bug：PopupPanel/ConfirmationDialog **不会自动吃掉未处理的按键**，
## 于是设置弹窗开着时按 R 会把对局重开、按空格还在翻格。这里显式让弹窗优先。
func _first_visible_popup() -> Window:
	var tree := get_tree()
	if tree == null:
		return null
	return _scan_window(tree.root)


func _has_open_popup() -> bool:
	return _first_visible_popup() != null


func _scan_window(n: Node) -> Window:
	for c in n.get_children():
		var w := _scan_window(c)
		if w != null:
			return w
		if c is Window and c != get_tree().root and (c as Window).visible:
			return c as Window
	return null


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	# ESC 关闭最上层弹窗（Godot 的 Window/Popup 不自带 ESC 关闭行为）
	if event.keycode == KEY_ESCAPE:
		var top := _first_visible_popup()
		if top != null:
			top.hide()
			accept_event()
			return
	if _has_open_popup():
		return
	if SettingsManager != null and not SettingsManager.keyboard_enabled:
		return
	if GameSession.state != GameSession.State.PLAYING:
		# R 重开是终局例外（HUD/GameOver 也有按钮；键盘通道同样允许）。
		# PAUSED 不放行：对局仍在进行，直接重开会绕过 ui_confirm 的二次确认（误触丢进度）。
		if event.keycode == KEY_R and GameSession.state == GameSession.State.ENDED:
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
	# ESC：暂停 / 继续（State.PAUSED 此前从未被任何 UI 触发，这里给它的真实入口）
	if event.keycode == KEY_ESCAPE:
		_toggle_pause()
		accept_event()
		return
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	@warning_ignore("shadowed_variable_base_class")
	var size := board.grid.size()
	var cur: Vector2i = GameSession.cursor
	var handled := true
	match event.keycode:
		KEY_R:
			_confirm_restart()
		KEY_Z:
			# 游戏操作撤销（与绘画模式的 Ctrl+Z 撤销笔迹独立：绘画模式此处分流不到这）
			if event.ctrl_pressed and not event.shift_pressed:
				GameSession.undo_move()
			else:
				handled = false
		KEY_F:
			GameSession.toggle_flag(cur)
		KEY_H:
			GameSession.request_hint()
		KEY_SPACE, KEY_ENTER:
			# 与鼠标同口径：光标停在已翻开的数字格上时执行一键展开
			if _quick_actions_enabled() and _is_revealed(cur):
				GameSession.chord(cur)
			else:
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


# ============ 暂停 / 破坏性操作确认 ============

## 暂停 / 继续。GameSession.set_paused 此前只有测试在调用，这里是它真实的 UI 入口。
func _toggle_pause() -> void:
	if GameSession.state == GameSession.State.PAUSED:
		GameSession.set_paused(false)
		if _pause_menu != null:
			_pause_menu.hide()
		queue_redraw()
	elif GameSession.state == GameSession.State.PLAYING:
		GameSession.set_paused(true)
		if _pause_menu != null:
			_pause_menu.popup_center_refreshed()
	


## 外部入口（HUD「暂停」按钮）。
func toggle_pause() -> void:
	_toggle_pause()


## 重开是不可撤销的破坏性操作：R 键与 WASD 光标键同处主键盘区，误触代价是丢整局。
## 判定口径统一放在 UiConfirm（HUD「重开」按钮与此处共用）。
func _confirm_restart() -> void:
	UiConfirm.confirm_restart(self, func(): GameSession.restart())


## 连携操作总开关（一键展开 chord + 右键拖动插旗）。默认开启，可在设置页关掉。
func _quick_actions_enabled() -> bool:
	return SettingsManager == null or SettingsManager.quick_actions


## 右键拖动状态（连续插旗）
var _flag_dragging := false
var _flag_drag_last: Vector2i = Vector2i(-1, -1)


## 拖动插旗：只对未翻开格生效（不取消已有旗）。
func _flag_if_hidden(pos: Vector2i) -> void:
	if GameSession.board == null or GameSession.board.grid == null:
		return
	if not GameSession.board.grid.in_board(pos):
		return
	var cell := GameSession.board.grid.get_cell(pos)
	if cell != null and cell.state == Cell.State.HIDDEN:
		GameSession.toggle_flag(pos)


## 该格是否已翻开（决定左键/空格走「翻开」还是「一键展开」）。
func _is_revealed(pos: Vector2i) -> bool:
	if GameSession.board == null or GameSession.board.grid == null:
		return false
	var cell := GameSession.board.grid.get_cell(pos)
	return cell != null and cell.state == Cell.State.REVEALED


func _pick(local_pos: Vector2) -> Vector2i:
	if cell_px <= 0:
		return Vector2i(-1, -1)
	var rel := local_pos - board_origin
	var c := floori(rel.x / float(cell_px))
	var r := floori(rel.y / float(cell_px))
	if GameSession.board == null or GameSession.board.grid == null:
		return Vector2i(-1, -1)
	@warning_ignore("shadowed_variable_base_class")
	var size := GameSession.board.grid.size()
	if c < 0 or c >= size.x or r < 0 or r >= size.y:
		return Vector2i(-1, -1)
	# 异形拓扑洞格：包围盒内的洞不是有效格（与 _draw/save/hud 的 all_positions 口径对齐）
	if GameSession.board.grid.get_cell(Vector2i(c, r)) == null:
		return Vector2i(-1, -1)
	return Vector2i(c, r)
