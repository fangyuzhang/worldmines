# board_view.gd —— 棋盘渲染 + 拾取 + 键盘 + 涟漪动效 + scale-to-fit【plan1.1 §10.7.6】
# 渲染只 queue_redraw() 交给 Godot 调度，禁手写脏矩形。
# 判负引爆格高亮从 GameSession.exploded_pos 取；终局揭晓绘制雷位允许调
# get_mine_positions()（渲染，非判负逻辑；红线 2 的例外条款）。
# 全部色值经 ThemeManager；无 48px 硬编码（全文件跟随 cell_px）。
#
# 几何抽象（T4）：所有「格坐标 → 像素」的换算集中到 _cell_center / _cell_rect / _cell_polygon
# 三个函数里，另加纯函数 _unit_px()（每晶格单位的像素数）。矩形关卡（RectGrid 或 style=="custom"
# 的邻接表）走原路径，逐像素等价；蜂窝（style=="hex"）走六边形几何（常量见下）。渲染之外的
# 动效状态机（wave / pop / ripple）与它们的时间常量**一律未动**，只吃传进去的矩形。
extends Control

# ============ 蜂窝（六边形）几何常量 ============
# 数值来源 = 原版游戏字节码（T4 已确证），**照用勿改**：
#   格心（晶格单位，(x,y) = 格坐标）：cx = 0.75*(x+y)、cy = (√3/4)*(x−y)
#   六边形外接半径 R = 0.475；相邻格心距 = √3/2 ≈ 0.866；内切半径 = (√3/2)R ≈ 0.4114。
#   ⇒ 两格内切半径和 ≈ 0.823 < 0.866，相邻格之间天然留 ~5% 缝——这是原版 0.95 收缩的复刻，
#     蜂窝盘看着「格与格分得开」正是它，**不要改成无缝**。
const HEX_R := 0.475                      # 六边形外接半径（晶格单位）
const HEX_SQ3 := 1.7320508075688772       # √3
const HEX_CX := 0.75                      # 格心 x 系数：cx = HEX_CX*(x+y)
const HEX_CY := HEX_SQ3 / 4.0             # 格心 y 系数：cy = HEX_CY*(x−y) = 0.4330127…
const HEX_SPACING := HEX_SQ3 / 2.0        # 相邻格心距 = √3/2 = 0.8660254…
const HEX_INRADIUS := HEX_SPACING * HEX_R # 内切半径 = (√3/2)R = 0.4113620…
## 六边形半高 = (√3/2)R：平顶六边形的**上下是水平边**，故这两条边到格心的距离就是内切半径
## （= HEX_INRADIUS，同一个数）。layout 的视觉包围盒上下各外扩这么多：只有外扩 R 就会把
## 最上/最下两排六边形切掉半个高度（首跑实测就是这么暴露的）。
const HEX_HALF_H := HEX_INRADIUS
const HEX_SQ_HALF := HEX_R / (1.0 + 1.0 / HEX_SQ3)  # 内接正方形半边长 = 0.3011379…
## 为什么内接正方形半边长是 0.3011 而不是「内切半径 0.4114」：
## 这个六边形是**平顶**的（顶点在左右，上下是水平边），左右两侧的斜边向内收。
## 半边长取 0.4114 时，正方形四角 (0.4114, 0.4114) 落在六边形**外面**（该处斜边只在 x ≤ 0.2375），
## 越过边长最多 0.174 晶格单位，而相邻格心仅相距 0.866 ⇒ 相邻格的正方形互相重叠约 1% 格面积，
## 整盘会糊成方阵的观感。取真正内接的正方形（0.3011）后正方形完全落在六边形内：
## 「六边形填充 ∪ 内接正方形填充 = 恰好六边形」，且与邻格零重叠（test_shape_style.gd 逐项断言）。
## 内接正方形仍以格心为中心，故数字/旗子/问号与各类覆盖层的**居中口径**与矩形路径完全一致。
const MIN_CELL_PX := 24                   # cell_px 下限（与矩形路径原公式的 24 同值同义）

## cell_px：scale-to-fit 动态格尺寸（§8.4.7 公式；下限 24px）
## 蜂窝路径下 = 内接正方形边长（像素），沿用 cell_px 是为了让既有「全部尺寸跟随 cell_px」的
## 绘制代码（字号 scale、旗子、提示描边…）零改动地跟着蜂窝盘一起缩放。
var cell_px: int = 48
## 棋盘绘制原点（恒居中）。矩形路径 = 格 (0,0) 的左上角；蜂窝路径 = 晶格原点（格心 = origin + 晶格坐标×unit）。
var board_origin: Vector2 = Vector2.ZERO
## 蜂窝路径的「每晶格单位像素数」（由 _layout() 按六边形实际跨度 scale-to-fit 算出）。
## 只经 _unit_px() 读取；矩形路径不使用。
var _hex_unit_px: float = 48.0
## 鼠标悬停格（-1,-1 = 无）
var hover_pos: Vector2i = Vector2i(-1, -1)

## 开格波浪参数（§8.4.5；0 间隙棋盘：波浪的本质是**相位差**，不是位移）。
##   WS 每环延迟秒 · WD 单格时长秒 · GLOW 网格线高亮上限 · WP 颜色脉冲权重
##   SHRINK 填充收缩幅度 · COVER 波及范围比例 · MAX_RINGS 扩散层数上限
##   DELAY_CAP 错峰上限秒 · TAIL_MULT 末环长尾倍率 · LINE_GAIN 高亮线宽增益
const WAVE_WS := 0.040        # 每环延迟（秒）：环 0/1 同时开始，环 2 起逐环错开
const WAVE_WD := 0.30         # 单格时长（秒）：waveE = sin(PI*t/WD)，唯一能精确回到 0
const WAVE_GLOW := 0.85       # 网格线混向高亮色的强度上限（本方案主通道）
const WAVE_WP := 0.75         # 颜色脉冲权重：峰值 alpha = WP * WAVE_PULSE_MAX
const WAVE_SHRINK := 0.04     # 填充原地收缩幅度（0 间隙下禁位移/放大）
const WAVE_COVER := 0.24      # 波及格数上限 = 总格数 × COVER（连续参数，跨环按 frac 衰减）
const WAVE_MAX_RINGS := 4     # 扩散层数上限（安全 + 收尾时长可控）
const WAVE_PULSE_MAX := 0.55  # 颜色脉冲相对 WP 的系数
## 错峰延迟上限（秒）：末环起播最多比环 0 晚这么久（`_ring_delay_sec` 逐环 min 封顶）。
## 为什么要显式封顶：环延迟随环序线性增长 (ring-1)*WS，泛洪范围一大（大盘 / 掀开整片）
## 最后一环就会等到几百毫秒才起播，观感从「一圈推开」变成「拖沓」。
## 封顶后超出的环共享同一启动时刻——波前在末环「追上」并一起收束，总时长因此有硬上限
## ＝ WAVE_DELAY_CAP + WAVE_WD * WAVE_TAIL_MULT（见 total_ms 计算）。
const WAVE_DELAY_CAP := 0.12
## 末环渐慢长尾倍率：只有**最后一环**的波形时长放大到 WAVE_WD 的该倍率。
## 目的：波前推到最外圈时不再「整环同时亮灭」地硬切，而是慢慢收束（渐慢长尾）。
## 内部环时长不变 → 既有节奏、既有测试都不受影响。
const WAVE_TAIL_MULT := 1.5
## 波浪高亮描边相对静止网格线的线宽增益：线宽 = 1.0 + GAIN*g ∈ [1.0, 1.6]。
## 只作用于被波浪波及、且该帧确有强度（g>0）的格——g=0 时精确回 1.0（非波浪帧零变化）。
const WAVE_LINE_GAIN := 0.6

## 单格翻开 pop 参数（动效规范两件套之「单格 pop」，与 0 格波浪并存）。
##   POP_WD 单格时长秒 · POP_SCALE_MIN 起始收缩比
## 规范初值：p = clamp((now-t0)/0.20, 0, 1)；e = sin(PI*p/2)（单调缓出）；
##           scale = 0.86 + 0.14*e；color = lerp(未翻开色, 已翻开色, e)。
## ⚠️ 关键约束（否则会压到邻格）：本项目格子间隙 = 0（cell_px 即格宽、网格线居中于格缝）。
## 规范原式的过冲项 `+ 0.10 * sin(PI*p)` 峰值可达 1.07 —— 零间隙下必然越线压住邻格。
## 故**砍掉过冲项**：scale 严格落在 [0.86, 1.0]，只收缩、永不超过 1.0。
const POP_WD := 0.20           # 单格 pop 时长（秒）：0.20s 内 scale 0.86→1.0、颜色插值完毕
const POP_SCALE_MIN := 0.86    # 起始收缩比例（0.86 收缩起 → 1.0 归位；上界恒为 1.0）

# 用 preload 而非全局类名：新增脚本的全局类缓存未必在加载本场景前刷新，
# 直接用 `RippleRings` 会解析失败（单元测试首跑已复现）。纯静态方法，preload 等价。
const RIPPLE_RINGS := preload("res://core/ripple_rings.gd")

## 开格波浪：同一时间最多一条（新波浪覆盖旧波浪，天然防叠加）。
## 每条记录 = { pos 环0起点, t0 触发时刻ms, ring_of{格->环}, amp_of{格->振幅},
##              total_rings 最后一环, ring_sizes 各环格数, ring_delays 各环起播延迟,
##              cells / target 供渐隐校验 }
var _ripples: Array = []
## 波浪触发源（v3.4 起）：Board.flood_planned 的**权威计划**——origin / cells / zero_flood。
## 此前在 UI 侧攒 cell_state_changed 做「同帧唯一格数 >= 2」的启发式判泛洪，已删除：
## 那个启发式会把 chord（逐目标展开）与终极模式揭星误报成 0 格泛洪（core 侧新增本信号即为取代它）。
## 波浪逐帧缓存（Vector2i -> {"s": 填充缩放, "g": 波浪强度 0..1}）。
## 原实现对每个格子 O(1) 扫描整个涟漪队列（连锁翻开时可达数十条），
## 大盘下变成 O(格子数 × 涟漪数)/帧。改为每帧只算一次几何，绘制时查表。
var _ripple_cache: Dictionary = {}
var _ripple_cache_ms: int = -1

## 单格 pop 登记表：Vector2i -> 该格本次翻开的起始时刻(ms)。
## 每次收到该格翻开事件就登记一次（泛洪时每格各一次，与波浪并存）。
## pop 结束（超过 POP_WD）后由 _cull_pops 从表中移除 → 不会无限增长。
var _pops: Dictionary = {}
## pop 逐帧缓存（Vector2i -> {"s": 缩放, "e": 缓出进度 0..1}）。
## 与 _ripple_cache 同范式：按 ms 重建、绘制只查表。两套缓存独立，互不覆盖。
var _pop_cache: Dictionary = {}
var _pop_cache_ms: int = -1

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
	# 换算本身仍是「棋盘坐标 → 屏幕」的线性映射（绘画层代码零改动），只是蜂窝盘要换成晶格仿射映射，
	# 否则笔记会整片错位（蜂窝的格心间距与矩形不同）。
	_drawing.set_board_transform(_board_pt_to_screen, _screen_pt_to_board)
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
	_ripple_cache.clear()
	_ripple_cache_ms = -1
	_pops.clear()
	_pop_cache.clear()
	_pop_cache_ms = -1
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
	# v3.4：波浪触发改用 Board 的**权威泛洪计划**（取代旧的「同帧唯一格数 >= 2」启发式）。
	if not GameSession.board.flood_planned.is_connected(_on_flood_planned):
		GameSession.board.flood_planned.connect(_on_flood_planned)


func _on_cell_changed(pos: Vector2i) -> void:
	_clear_hint()  # 盘面变化 → 旧推理结论失效
	# 单格 pop：每次翻开该格都登记一次（数字格/任意单格都有反馈）。
	# 泛洪时每个被翻开的格子都会各走一次本分支 → 每格各有一次 pop，与波浪并存。
	# 注意：波浪**不在这里**触发——它只由 Board.flood_planned(zero_flood=true) 驱动（见下）。
	if GameSession.board != null and GameSession.board.grid != null:
		var cell := GameSession.board.grid.get_cell(pos)
		if cell != null and cell.state == Cell.State.REVEALED and _reveal_effects_enabled():
			_register_pop(pos)
	queue_redraw()


## v3.4：0 格泛洪的权威计划 → 以 origin 为环 0、cells 为实际翻开集合起一条波浪（按环错峰）。
##
## 为什么只认 zero_flood=true：单格翻开（数字格 / FR 的 0 / 孤立 0 格）的反馈是
## _on_cell_changed 登记的单格 pop；把它塞进环序错峰既无意义又会与 pop 打架。
## chord 逐目标展开（每个目标各发一次 zero_flood=false）同理不产生波浪。
##
## 时序承诺：本信号在逐格 cell_state_changed 全部发完后、**同一个同步调用内**发出，
## 此刻棋盘状态已是最终态。这里只做「演出」，绝不回写状态、也绝不延迟任何状态变更——
## 动画的错峰只体现在绘制层（_ripples / _ripple_cache），与 Board 的时序完全解耦。
func _on_flood_planned(origin: Vector2i, cells: Array[Vector2i], zero_flood: bool) -> void:
	if not zero_flood:
		return
	if not _reveal_effects_enabled():
		return
	_start_wave(origin, cells)


## 登记一次单格 pop（记录起始时刻）。同一格重复 emit 只保留最新一次起算时刻。
## 复用「登记表 + _process 重算 + 按 ms 缓存」范式（不引入 Tween / 节点）。
## 总闸由调用方 _on_cell_changed 把关；此处只负责登记并唤醒逐帧回调。
func _register_pop(pos: Vector2i) -> void:
	_pops[pos] = float(Time.get_ticks_msec())
	_pop_cache_ms = -1
	_request_frames()


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
	# 可用区域的中心：矩形路径的 board_origin 公式隐含就是这个中心，蜂窝路径直接用它对齐。
	var avail_center := Vector2(vp.x * 0.5, 64.0 + avail_h * 0.5)
	# 蜂窝：按六边形**实际几何跨度**（不是 grid.size() 包围盒方阵）做 scale-to-fit。
	# 用包围盒算会按 size×size 的正方形分配空间，六边形盘的斜边留白全被浪费 ⇒ 盘明显偏小。
	if _hex_layout():
		var layout := hex_layout_for(GameSession.board.grid.all_positions(), avail_w, avail_h, avail_center)
		_hex_unit_px = float(layout["unit_px"])
		cell_px = maxi(int(layout["cell_px"]), MIN_CELL_PX)
		board_origin = layout["origin"]
		queue_redraw()
		return
	# ↓ 矩形路径：以下逐行是原实现（唯一改动 = 字面量 24 → 同值常量 MIN_CELL_PX）。
	cell_px = maxi(floori(min(avail_w / float(cols), avail_h / float(rows))), MIN_CELL_PX)
	var board_w: float = float(cols) * cell_px
	var board_h: float = float(rows) * cell_px
	board_origin = Vector2((vp.x - board_w) * 0.5, 64.0 + (avail_h - board_h) * 0.5)
	queue_redraw()


# ============ 几何抽象（矩形 / 蜂窝两套坐标映射的唯一出口） ============

## 当前盘面是否按蜂窝（六边形）几何排布。唯一判据 = 邻接表的 style == "hex"
## （ShapeGenerator.build_hex / 落盘 topology.style 得来）。矩形关卡与旧异形拓扑恒 false
## ⇒ 本文件其余分支全部走原路径，行为零变化。
func _hex_layout() -> bool:
	var b: Board = GameSession.board
	if b == null or b.grid == null:
		return false
	var g: GridInterface = b.grid
	return g is AdjacencyGrid and (g as AdjacencyGrid).has_hex_layout()


## 每「晶格单位」的像素数。
## 矩形路径：1 单位 = 1 格 = cell_px（于是 _cell_center 与旧式 board_origin + (c,r)*cell_px 逐像素等价）。
## 蜂窝路径：1 单位 = 原版晶格单位（0.75 / √3÷4 的格心步长、0.475 的外接半径都以它为单位）。
func _unit_px() -> float:
	return _hex_unit_px if _hex_layout() else float(cell_px)


## 格心（像素）。矩形路径 = 原格矩形中心；蜂窝路径 = 六边形格心。
func _cell_center(pos: Vector2i) -> Vector2:
	if _hex_layout():
		return hex_center_px(pos, _hex_unit_px, board_origin)
	return board_origin + Vector2(pos.x, pos.y) * float(cell_px) + Vector2(cell_px, cell_px) * 0.5


## 格位绘制矩形（_draw_cell 与全部覆盖层共用）。
## 矩形路径 = **原实现原式**（逐像素等价）；蜂窝路径 = 以格心为中心的内接正方形（见 HEX_SQ_HALF）。
func _cell_rect(pos: Vector2i) -> Rect2:
	if not _hex_layout():
		return Rect2(board_origin + Vector2(pos.x, pos.y) * cell_px, Vector2(cell_px, cell_px))
	var s := 2.0 * HEX_SQ_HALF * _unit_px()
	return Rect2(_cell_center(pos) - Vector2(s, s) * 0.5, Vector2(s, s))


## 格子的多边形轮廓：蜂窝 = 6 顶点六边形；其余 = 该格矩形的 4 角（顺时针）。
func _cell_polygon(pos: Vector2i) -> PackedVector2Array:
	if _hex_layout():
		return hex_polygon_px(pos, _hex_unit_px, board_origin)
	var r := _cell_rect(pos)
	return PackedVector2Array([
		r.position,
		r.position + Vector2(r.size.x, 0.0),
		r.position + r.size,
		r.position + Vector2(0.0, r.size.y),
	])


## 格子底色（与 _draw_cell 的状态分支同口径；REVEALED 时含 pop 颜色插值）。
## 蜂窝几何下先由 _draw() 填六边形、再让 _draw_cell 填内接正方形——两处必须同色，
## 否则会看到「六边形里嵌着一个方块」。
func _cell_base_color(cell: Cell, pop_e: float) -> Color:
	if cell.state == Cell.State.REVEALED:
		var base := ThemeManager.cell_revealed()
		if pop_e < 1.0:
			base = ThemeManager.cell_hidden().lerp(base, pop_e)
		return base
	return ThemeManager.cell_hidden()


# ============ 蜂窝几何纯函数（static：渲染与单测共用同一份公式，可脱离场景树验证） ============

## 格心（晶格单位，与像素无关）：cx = 0.75*(x+y)、cy = (√3/4)*(x−y)。
static func hex_center_lattice(pos: Vector2i) -> Vector2:
	return Vector2(HEX_CX * float(pos.x + pos.y), HEX_CY * float(pos.x - pos.y))


## 格心（像素）= origin + 晶格坐标 × unit_px。
static func hex_center_px(pos: Vector2i, unit_px: float, origin: Vector2) -> Vector2:
	return origin + hex_center_lattice(pos) * unit_px


## 六边形 6 顶点（晶格单位，相对格心；顺序照原版：右 → 右上 → 左上 → 左 → 左下 → 右下）。
static func hex_vertex_units() -> PackedVector2Array:
	var r := HEX_R
	var h := HEX_SPACING * HEX_R   # (√3/2)R：上下两条水平边距格心的距离
	return PackedVector2Array([
		Vector2(r, 0.0),
		Vector2(r * 0.5, -h),
		Vector2(-r * 0.5, -h),
		Vector2(-r, 0.0),
		Vector2(-r * 0.5, h),
		Vector2(r * 0.5, h),
	])


## 某格的六边形顶点（像素）。shrink ≤ 1 时绕格心等比收缩——复用 wave / pop 已算好的收缩比，
## 让动效在蜂窝盘上也「看得见」（不改动那两个状态机本身）。
static func hex_polygon_px(pos: Vector2i, unit_px: float, origin: Vector2, shrink: float = 1.0) -> PackedVector2Array:
	var c := hex_center_px(pos, unit_px, origin)
	var out := PackedVector2Array()
	for v in hex_vertex_units():
		out.append(c + v * unit_px * shrink)
	return out


## 格心范围的包围盒（晶格单位）：position = 最小格心，size = 跨度。
static func hex_lattice_bounds(positions: Array) -> Rect2:
	if positions.is_empty():
		return Rect2(Vector2.ZERO, Vector2.ZERO)
	var min_c := Vector2(INF, INF)
	var max_c := Vector2(-INF, -INF)
	for p: Vector2i in positions:
		var c := hex_center_lattice(p)
		min_c = Vector2(minf(min_c.x, c.x), minf(min_c.y, c.y))
		max_c = Vector2(maxf(max_c.x, c.x), maxf(max_c.y, c.y))
	return Rect2(min_c, max_c - min_c)


## 蜂窝盘的视觉包围盒尺寸（晶格单位）= 格心跨度 + 六边形外扩（左右各 R、上下各半高 (√3/2)R）。
## 注意：**不能**用 grid.size()（= size×size 包围盒方阵）——六边形盘的 bbox 四角大半是盘外格，
## 按 bbox 分配空间会让盘明显偏小、留白全堆在四个角。
static func hex_visual_span(positions: Array) -> Vector2:
	var b := hex_lattice_bounds(positions)
	if b.size == Vector2.ZERO:
		return Vector2.ZERO
	return b.size + Vector2(2.0 * HEX_R, 2.0 * HEX_HALF_H)


## 蜂窝布局（纯函数）：在 avail_w×avail_h 的可用区域里按视觉跨度做 scale-to-fit，并居中。
## 返回 {unit_px, origin, span, cell_px}：
##   unit_px —— 每晶格单位像素数；origin —— 晶格原点（格心 = origin + 晶格坐标×unit）；
##   span    —— 视觉跨度（晶格单位，便于核对/报告）；cell_px —— 内接正方形边长（像素，= 渲染用的 cell_px）。
static func hex_layout_for(positions: Array, avail_w: float, avail_h: float, center: Vector2) -> Dictionary:
	var span := hex_visual_span(positions)
	if span.x <= 0.0 or span.y <= 0.0:
		return {"unit_px": 0.0, "origin": center, "span": Vector2.ZERO, "cell_px": 0}
	var unit := minf(avail_w / span.x, avail_h / span.y)
	var sq := 2.0 * HEX_SQ_HALF * unit
	if sq < float(MIN_CELL_PX):
		# 与矩形路径的 24px 下限同口径：窗口极小时宁可溢出，也不把格子缩成一团糊。
		sq = float(MIN_CELL_PX)
		unit = sq / (2.0 * HEX_SQ_HALF)
	# 左右/上下的外扩是对称的 ⇒ 视觉包围盒中心 == 格心跨度中点，直接拿它对准可用区中心即可。
	var bounds := hex_lattice_bounds(positions)
	var mid := bounds.position + bounds.size * 0.5
	return {
		"unit_px": unit,
		"origin": center - mid * unit,
		"span": span,
		"cell_px": int(round(sq)),
	}


## 棋盘坐标（单位 = 格，可为小数）→ 屏幕（绘画层注入的两个换算之一）。
## 矩形 = 旧式线性映射（逐像素不变）；蜂窝 = 晶格仿射映射。
func _board_pt_to_screen(p: Vector2) -> Vector2:
	if _hex_layout():
		return board_origin + Vector2(HEX_CX * (p.x + p.y), HEX_CY * (p.x - p.y)) * _unit_px()
	return board_origin + p * cell_px


## 屏幕 → 棋盘坐标（_board_pt_to_screen 的逆；两者必须互补，否则笔记会漂）。
func _screen_pt_to_board(p: Vector2) -> Vector2:
	if _hex_layout():
		var v := (p - board_origin) / maxf(_unit_px(), 0.0001)
		var s := v.x / HEX_CX            # = x + y
		var d := v.y / HEX_CY            # = x − y
		return Vector2((s + d) * 0.5, (s - d) * 0.5)
	return (p - board_origin) / float(maxi(cell_px, 1))


func _process(_delta: float) -> void:
	var now_ms := Time.get_ticks_msec()
	var dirty := false
	# 总开关关闭：立刻丢弃在途波浪/单格 pop 与缓存 → 下一次重绘即静止态
	#（无收缩、无高亮残留；pop 清掉后该格 scale 回 1.0、颜色走状态色）。
	if not _reveal_effects_enabled() and (not _ripples.is_empty() or not _pops.is_empty()):
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
	# 单格 pop：与波浪同帧驱动、互不覆盖；结束后从登记表移除（防无限增长）。
	if not _pops.is_empty():
		_cull_pops(now_ms)
		_pop_cache_ms = -1
		dirty = true
	if dirty:
		queue_redraw()
	# 无动画时彻底关掉逐帧回调：静态棋盘不需要每帧醒来
	if _ripples.is_empty() and _pops.is_empty() and _hint_until_ms < 0 and _reject_until_ms < 0:
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


## 淘汰已结束（超过 POP_WD）的单格 pop。返回是否发生了变化。
## 结束后从登记表移除 → 表不无限增长；移除后该格查不到 pop → scale 恰为 1.0（无残留）。
## 抽成带参函数：测试可注入时钟验证收尾，不依赖真实时间。
func _cull_pops(now_ms: int) -> bool:
	if _pops.is_empty():
		return false
	var before := _pops.size()
	var dur_ms: float = POP_WD * 1000.0
	# 不用 Dictionary.filter（本引擎版本无此方法）：手工保留未结束项。
	var kept := {}
	for pos in _pops:
		if float(now_ms) - float(_pops[pos]) < dur_ms:
			kept[pos] = _pops[pos]
	if kept.size() == before:
		return false
	_pops = kept
	if _pops.is_empty():
		_pop_cache.clear()
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
	# 这里再兜底清一次在途波浪/单格 pop，保证任何重绘入口（窗口缩放/主题切换/测试直调）都无残留。
	var effects_on := _reveal_effects_enabled()
	if not effects_on and (not _ripples.is_empty() or not _pops.is_empty()):
		_clear_wave_state()

	var hex := _hex_layout()
	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var cell := board.grid.get_cell(pos)
			# 异形拓扑（AdjacencyGrid）洞格返回 null（口径与 save/hud/stats 的 all_positions 对齐）：
			# 此前直接 _draw_cell(null) 空引用中止 _draw → 棋盘渲染整体失效。
			if cell == null:
				continue
			var rect := _cell_rect(pos)
			# 翻开动效几何：波浪 + 单格 pop **相乘**（s_total = s_pop × s_wave）。
			# 两者都 ≤1.0 → 零间隙下相乘只会更小、天然不可能压到邻格。关闭总闸时走原矩形。
			var rrect: Rect2 = _reveal_rect_for(pos, rect) if effects_on else rect
			# pop 颜色插值进度（0→1；无 pop = 1.0 = 状态色），供 _draw_cell 混色
			var pop_e: float = _pop_progress(pos) if effects_on else 1.0
			# 蜂窝：六边形本体在这里填（背景层），_draw_cell 只负责内接正方形与内容。
			# 两者同色（_cell_base_color）⇒ 正方形被六边形完全覆盖 = 恰好一个六边形。
			# 收缩比直接取自 rrect（wave/pop 既有几何）→ 动效在蜂窝盘上照样「原地收缩」，
			# 而**没有**改动那两个状态机的任何一行。
			if hex:
				var shrink := rrect.size.x / maxf(rect.size.x, 0.001)
				draw_colored_polygon(hex_polygon_px(pos, _hex_unit_px, board_origin, shrink),
						_cell_base_color(cell, pop_e))
			_draw_cell(pos, cell, rrect, scale, font, endgame, pop_e)

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
		# grow(-1) 与旧式「position+1 / size−2」逐像素等价（矩形路径），蜂窝则自动落在六边形格心。
		var crect := _cell_rect(session.cursor).grow(-1.0)
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
	var rect := _cell_rect(_reject_pos).grow(-2.0)
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
			var rect := _cell_rect(p).grow(-2.0)
			var col := ThemeManager.safe() if step.state == "safe" else ThemeManager.danger()
			draw_rect(rect, col, false, 3.0 * maxf(scale, 0.6))
		for src in step.sources:
			var sp: Vector2i = src
			if not GameSession.board.grid.in_board(sp):
				continue
			var srect := _cell_rect(sp).grow(-1.0)
			var scol := ThemeManager.accent()
			scol.a = 0.8
			draw_rect(srect, scol, false, 2.0)


@warning_ignore("shadowed_variable_base_class")
@warning_ignore("unused_parameter")
func _draw_cell(pos: Vector2i, cell: Cell, rect: Rect2, scale: float, font: Font, endgame: bool, pop_e: float = 1.0) -> void:
	match cell.state:
		Cell.State.HIDDEN:
			draw_rect(rect, ThemeManager.cell_hidden())
		Cell.State.FLAGGED:
			_draw_flag(rect, scale)
		Cell.State.QUESTION:
			draw_rect(rect, ThemeManager.cell_hidden())
			_draw_question(rect, scale, font)
		Cell.State.REVEALED:
			# 单格 pop 的颜色通道：由「瞬变」改为 0.20s 内 未翻开色 → 已翻开色 插值。
			# pop_e = sin(PI*p/2) ∈ [0,1]；无 pop（静止/未登记）时传 1.0 → 精确取状态色。
			var base := ThemeManager.cell_revealed()
			if pop_e < 1.0:
				base = ThemeManager.cell_hidden().lerp(base, pop_e)
			draw_rect(rect, base)
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
		var rect := _cell_rect(m)
		if m == exploded:
			# 引爆格高亮：蜂窝下按六边形填，方阵路径保持原 draw_rect。
			if _hex_layout():
				draw_colored_polygon(_cell_polygon(m), ThemeManager.danger())
			else:
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
	draw_rect(_cell_rect(center_pos), ThemeManager.hover_center_overlay())
	if not with_neighbors:
		return
	# 周围 8 邻（按实际存在的邻格）
	# 注：邻域仍按**包围盒偏移**枚举（矩形 8 邻语义），蜂窝盘上落在盘外的偏移由 in_board 过滤掉——
	# 悬停「柔光」是纯装饰，不值得为它引入拓扑邻接（真正的邻接关系只有线索语义需要）。
	for d in [Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1)]:
		var np: Vector2i = center_pos + d
		if board.grid.in_board(np):
			draw_rect(_cell_rect(np), ThemeManager.hover_neighbor_overlay())


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


## 丢弃全部翻开动效状态（波浪 + 单格 pop）与几何缓存（新对局 / 关掉总开关时复用）。
## 缓存必须同步清空——否则绘制层会残留收缩与线色高亮（收尾无残留是硬约束）；
## pop 清空后该格查不到记录 → scale 回 1.0、颜色走状态色（同样无残留）。
func _clear_wave_state() -> void:
	_ripples.clear()
	_ripple_cache.clear()
	_ripple_cache_ms = -1
	_pops.clear()
	_pop_cache.clear()
	_pop_cache_ms = -1


# ============ 单格 pop（动效规范两件套之一；与波浪**相乘**合成） ============

## 合成波浪 + pop 的绘制矩形：先取波浪收缩，再叠加 pop 收缩（两次都是绕中心相乘）。
## s_total = s_pop × s_wave，两者都落在 [0,1] → 相乘只会更小，零间隙下天然不可能压到邻格。
func _reveal_rect_for(pos: Vector2i, rect: Rect2) -> Rect2:
	return _pop_rect_for(pos, _ripple_rect_for(pos, rect))


## pop 活跃期返回原地收缩后的绘制矩形（在传入矩形上绕中心乘 s_pop）；否则原样返回。
func _pop_rect_for(pos: Vector2i, rect: Rect2) -> Rect2:
	var s := _pop_scale_at(pos)
	if s >= 1.0:
		return rect
	var half: Vector2 = rect.size * 0.5 * s
	var cpos: Vector2 = rect.position + rect.size * 0.5
	return Rect2(cpos - half, half * 2.0)


## 该格当前 pop 缩放：POP_SCALE_MIN + (1-POP_SCALE_MIN)*e（e 单调缓出）。
## 无记录（未登记 / 已结束被淘汰）→ 1.0（静止态，恒 <= 1.0）。at_ms 仅供测试注入时钟。
func _pop_scale_at(pos: Vector2i, at_ms: int = -1) -> float:
	var rec := _pop_rec(pos, at_ms)
	return float(rec["s"]) if not rec.is_empty() else 1.0


## 该格 pop 颜色插值进度 e ∈ [0,1]；无记录 → 1.0（= 已翻开色，静止态）。
## at_ms 仅供测试注入时钟。
func _pop_progress(pos: Vector2i, at_ms: int = -1) -> float:
	var rec := _pop_rec(pos, at_ms)
	return float(rec["e"]) if not rec.is_empty() else 1.0


## 查该格 pop 缓存记录（必要时按当前/注入时钟重算）。无记录返回空字典。
func _pop_rec(pos: Vector2i, at_ms: int = -1) -> Dictionary:
	if _pops.is_empty():
		return {}
	var now_ms := at_ms if at_ms > 0 else Time.get_ticks_msec()
	if _pop_cache_ms != now_ms:
		_rebuild_pop_cache(now_ms)
	return _pop_cache.get(pos, {})


## 重算 pop 缩放/进度缓存。at_ms 仅供测试注入时钟（<= 0 → 真实时钟）。
## p = clamp((now - t0)/POP_WD, 0, 1)；e = sin(PI*p/2)（单调缓出 0→1）；
## s = POP_SCALE_MIN + (1-POP_SCALE_MIN)*e ∈ [0.86, 1.0]（已砍过冲项，见 POP_WD 注释）。
func _rebuild_pop_cache(at_ms: int = -1) -> void:
	_pop_cache.clear()
	_pop_cache_ms = at_ms if at_ms > 0 else Time.get_ticks_msec()
	var now_ms := _pop_cache_ms
	var dur_ms: float = POP_WD * 1000.0
	for pos in _pops:
		var p: float = clampf(float(now_ms - float(_pops[pos])) / dur_ms, 0.0, 1.0)
		var e: float = sin(PI * p * 0.5)
		_pop_cache[pos] = {"e": e, "s": POP_SCALE_MIN + (1.0 - POP_SCALE_MIN) * e}


# ============ 开格波浪（§8.4.5 重写：图距离分环 + 相位差；0 间隙只走收缩/颜色通道） ============

## 环 ring 相对环 0 的起播延迟（秒）= 时间模型 delay_of 再按 WAVE_DELAY_CAP 封顶。
## 封顶策略见常量注释：环再多也不让末环无限等，总时长因此有硬上限。
func _ring_delay_sec(ring: int) -> float:
	return minf(RIPPLE_RINGS.delay_of(ring, WAVE_WS), WAVE_DELAY_CAP)


## 以 start 为环 0 起点构建一条波浪：RippleRings 按图距离分环 → 逐环错峰延迟 → cover 渐隐。
## 环内顺序不影响观感（同环延迟相同）；0 间隙下禁用位移与放大。
##
## cells：Board.flood_planned 给的**本次实际 HIDDEN→REVEALED 集合**。
##   非空 → 波浪只波及这些格（不再去点亮尚未翻开的格；环由 RippleRings 按图距离算出，
##          再与泛洪集合取交——环序错峰保证是「一圈推开」而不是「整片闪一下」）。
##   空   → 退化路径：按几何环取全盘（保留给直接调用 / 单测的兼容入口）。
func _start_wave(start: Vector2i, cells: Array = []) -> void:
	# 双保险：即便调用方（_on_flood_planned）没拦，关闭时也绝不建立波浪。
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
	# 权威泛洪集合（非空时只让「本次真正翻开的格」参与波浪）。
	var flood_only := not cells.is_empty()
	var in_flood := {}
	for p in cells:
		in_flood[p] = true
	# 逐环收集成员：flood_only 时与泛洪集合取交（空环直接跳过，不影响环序）。
	var ring_members: Array = []
	var total_cells := 0
	for ring in rings:
		var members: Array = []
		for p in (ring as Array):
			if not flood_only or in_flood.has(p):
				members.append(p)
		ring_members.append(members)
		total_cells += members.size()
	if total_cells <= 0:
		return
	# cover 是连续参数：波及格数达到 总格数 × COVER 即停；跨过目标的那一环按
	# frac = (target - 已累计) / 环内格数 衰减振幅，避免「多一格就整环全亮」的阶跃。
	var target: int = maxi(int(floor(float(total_cells) * WAVE_COVER)), 1)
	var ring_of := {}
	var amp_of := {}
	var ring_sizes: Array = []
	var cum := 0
	var last_ring := 0
	for i in ring_members.size():
		var members: Array = ring_members[i]
		var n: int = members.size()
		if n <= 0:
			continue
		var frac := 1.0
		if cum + n > target:
			frac = clampf(float(target - cum) / float(n), 0.0, 1.0)
		if frac > 0.0:
			for p in members:
				ring_of[p] = i
				amp_of[p] = frac
			ring_sizes.append(n)
			last_ring = i
		cum += n
		if cum >= target:
			break
	if ring_of.is_empty():
		return
	# 环起播延迟表（0..last_ring）：仅供演出/校验读取，单调不降且末值 ≤ WAVE_DELAY_CAP。
	var ring_delays: Array = []
	for i in range(last_ring + 1):
		ring_delays.append(_ring_delay_sec(i))
	# 打架处理：**新波浪覆盖旧波浪**（clear 后只留这一条）。
	# 为什么选覆盖而非合并/排队：① 同一时间只有一条波浪 → 零叠加风险、收尾判断简单（无残留）；
	# ② 玩家连点时后一次点击才是意图焦点，旧波把 t0 归零重放会与新波互相打断；
	# ③ 分环只影响绘制层，覆盖不会改变任何格的状态（状态早已是最终态）。
	_ripples.clear()
	_ripples.append({
		"pos": start,
		"t0": float(Time.get_ticks_msec()),
		"ring_of": ring_of,
		"amp_of": amp_of,
		"total_rings": last_ring,
		"ring_sizes": ring_sizes,
		"ring_delays": ring_delays,
		"cells": ring_of.size(),
		"target": target,
		# 总时长 = 末环起播延迟 + 末环时长（含长尾）→ _process 依此淘汰，结束后无残留。
		# 上界 = WAVE_DELAY_CAP + WAVE_WD * WAVE_TAIL_MULT（错峰与收尾都有硬上限）。
		"total_ms": (_ring_delay_sec(last_ring) + WAVE_WD * _ring_wd_mult(last_ring, last_ring)) * 1000.0,
	})
	_ripple_cache_ms = -1
	_request_frames()


## 环 ring 的波形时长倍率：只有最后一环走「渐慢长尾」（WAVE_TAIL_MULT），其余环恒为 1。
## last_ring 由调用方传入（同一记录的末环），避免在记录尚未入队时反查全局状态。
func _ring_wd_mult(ring: int, last_ring: int) -> float:
	return WAVE_TAIL_MULT if ring == last_ring else 1.0


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
## 时间轴：t = (now - t0)/1000 - 环起播延迟(ring)，waveE = sin(PI*clamp(t/WD,0,1))*振幅。
## 末环的 WD 放大 WAVE_TAIL_MULT（渐慢长尾）；waveE 是唯一能精确回到 0 的曲线，
## 故动画收尾绝不残留（s 回 1.0、线色回原值）——长尾只改时长，不改「归零」性质。
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
		var last_ring: int = int(rp["total_rings"])
		for pos in ring_of:
			var ring: int = int(ring_of[pos])
			var wd: float = WAVE_WD * _ring_wd_mult(ring, last_ring)
			var t: float = float(now_ms - t0) / 1000.0 - _ring_delay_sec(ring)
			var e: float = sin(PI * clampf(t / wd, 0.0, 1.0)) * float(amp_of.get(pos, 1.0))
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
		draw_rect(_cell_rect(pos), col)


## 波浪高亮描边的线宽：静止 1.0，随波浪强度 g 线性加粗到 1.0 + WAVE_LINE_GAIN。
## 收尾质感项「涟漪线的线宽」：波前经过时线略粗 → 边缘更锐、更「立」；
## g=0 时精确回 1.0（非波浪帧与旧行为逐像素一致，避免静态棋盘观感变化）。
func _grid_line_width(g: float) -> float:
	return 1.0 + WAVE_LINE_GAIN * clampf(g, 0.0, 1.0)


## 网格线独立绘制遍（0 间隙方案的主通道）。
## 几何永远取自**原格矩形**，填充即使在收缩，线层也不动 → 线永远笔直。
## 受波及格描边颜色按 glow*waveE 混向高亮色、线宽按 _grid_line_width(waveE) 略粗；
## waveE=0 时精确回到 grid_line 原色 + 1.0 线宽（无残留）。抗锯齿只在被波及格开启。
##
## 蜂窝分支（二选一里的「按六边形描边」，而非「跳过」）：矩形网格线切进六边形内部会毁掉形状，
## 而波浪高亮线宽/线色是本方案的主通道，整遍跳过等于让蜂窝盘丢掉波浪反馈。故这里逐格描
## **六边形轮廓**（几何取自不收缩的 _cell_polygon，与填充收缩解耦 ⇒ 「线永远笔直」的不变量照旧）。
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
	if _hex_layout():
		for p: Vector2i in board.grid.all_positions():
			var col := line
			var lw := 1.0
			if has_wave:
				var e: Dictionary = _ripple_cache.get(p, {})
				if not e.is_empty():
					var g: float = float(e["g"])
					col = line.lerp(glow, WAVE_GLOW * g)
					lw = _grid_line_width(g)
			var poly := _cell_polygon(p)
			poly.append(poly[0])   # 闭合（draw_polyline 画的是折线）
			draw_polyline(poly, col, lw, lw > 1.0)
		return
	for r in board_size.y:
		for c in board_size.x:
			var pos := Vector2i(c, r)
			if board.grid.get_cell(pos) == null:
				continue  # 异形拓扑洞格（与填充遍同口径）
			var rect := Rect2(board_origin + Vector2(c, r) * cell_px, Vector2(cell_px, cell_px))
			var col := line
			var lw := 1.0
			if has_wave:
				var e: Dictionary = _ripple_cache.get(pos, {})
				if not e.is_empty():
					var g: float = float(e["g"])
					col = line.lerp(glow, WAVE_GLOW * g)
					lw = _grid_line_width(g)
			# 只有被波浪波及（lw>1）时才开抗锯齿：静态帧保持原绘制路径不变。
			draw_rect(rect, col, false, lw, lw > 1.0)


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
	if GameSession.board == null or GameSession.board.grid == null:
		return Vector2i(-1, -1)
	if _hex_layout():
		return _pick_hex(local_pos)
	var rel := local_pos - board_origin
	var c := floori(rel.x / float(cell_px))
	var r := floori(rel.y / float(cell_px))
	@warning_ignore("shadowed_variable_base_class")
	var size := GameSession.board.grid.size()
	if c < 0 or c >= size.x or r < 0 or r >= size.y:
		return Vector2i(-1, -1)
	# 异形拓扑洞格：包围盒内的洞不是有效格（与 _draw/save/hud 的 all_positions 口径对齐）
	if GameSession.board.grid.get_cell(Vector2i(c, r)) == null:
		return Vector2i(-1, -1)
	return Vector2i(c, r)


## 蜂窝命中测试：取最近的格心，距离 ≤ 内切半径 × 1.15 才算命中（否则返回 -1,-1）。
## 为什么取「最近格心」而不是像矩形那样反算行列：六边形格心是斜交晶格，且盘是被**截断**的
## （包围盒内有洞格），反算出的最近格可能落在盘外还得再做邻居搜索——本盘最多几十格，直接扫全格心
## 更短也更不容易写错。1.15 的宽容：相邻格心距 0.866 > 两格内切半径和 0.823，六边形之间本就留了
## ~5% 的缝，恰好点在缝里时不该「点了个空」（也顺便盖住半个格子的边缘误点）。
func _pick_hex(local_pos: Vector2) -> Vector2i:
	var limit := HEX_INRADIUS * 1.15 * _unit_px()
	var best := Vector2i(-1, -1)
	var best_d := limit
	for p: Vector2i in GameSession.board.grid.all_positions():
		var d := local_pos.distance_to(_cell_center(p))
		if d <= best_d:
			best_d = d
			best = p
	return best
