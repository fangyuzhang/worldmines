# level_select.gd —— 关卡选择：主网状节点图 + 变体关卡浮动弹窗
#
# 结构：
#   主界面  中心核心节点（经典）+ 若干分支节点（变体），节点间连线；
#           悬停缩放；点击分支/中心弹出关卡选择；窗口缩放自动重排 + 重绘连线。
#   弹窗    固定尺寸（切换内容不缩放）：尺寸选择栏 + 关卡网格同一容器框（选中蓝色高亮发光）
#           + 网格右侧竖排分页圆点 + 右侧面板（通关统计 / 继续·开始游戏）。
#
# 数据：每个模式 × 4 种棋盘尺寸（5×5/6×6/7×7/8×8）= 一套独立关卡列表（LEVELS_PER_SET 关）。
#      关卡由种子确定性生成（同 seed 必同盘），首次进入某套时预置前若干关为已通关（模拟存档）。
extends Control

# ===== 常量 =====
# 序列相关的常量统一托管在 LevelSequence（终局页要靠它算「下一关」，两处必须同源）。
const LEVELS_PER_SET := LevelSequence.LEVELS_PER_SET   # 每套关卡数
const SIZES: Array = LevelSequence.SIZES
const PAGE_SIZE := 20           # 一页最多 20 关
const GRID_COLS := 5            # 网格 5 列
## 删线索阶段墙钟上限（ms），按尺寸分档。实测：≤7×7 用 3s 即可删到最优（4~10 线索）；
## 8×8 是瓶颈（3s→22 线索、4s→19、60s→9，收益递减）——3s 保证交互响应，线索略多但可接受；
## 9×9 单关 CP-SAT 约 6~12s（32 雷），3s 必超时失败，故单列 15s（GDD 03 号 8×8≤10s 之外）。
func _gen_timeout(size: int) -> int:
	if size >= 9:
		return 15000
	return 3000


## 生成耗时预览（按钮文案用）：按尺寸的实测经验值（classic 线索，自由模式口径）。
func _estimate_gen_seconds(size: int) -> int:
	if size >= 9:
		return 12
	if size >= 8:
		return 4
	return 1
const MOCK_CLEARED := 1         # 模拟存档：首次进入预置已通关数（3 关中预置 1 关，定位到第 2 关）
const SCROLL_THRESHOLD := 2.0   # 滚轮累积阈值（factor 单位）
const ANIM := 0.22              # 统一过渡时长（0.2~0.25s）
const POPUP_SIZE := Vector2(1040, 640)
const TILE := Vector2(116, 84)

# 变体表（GDD 01 号：15 变体 = C0~C7 线索型 + G1~G7 全局约束；另含混合组合档）
# 字段：
#   kind    core=中心基线 / clue=C 类线索型 / global=G 类全局约束 / mixed=混合组合
#   clue    喂给规则平台的线索规则 id；globals 为全局约束规则 id 数组
#   enabled false = 暂不开放关卡（弹窗可看，按钮禁用）
# 中心为 C0 经典基线；内圈 C 类、中圈 G 类、外圈混合档（分层同心圆布局）。
const MODES: Array = [
	# ---- 中心：C0 经典（基线变体）----
	{"id": "classic", "name": "经典", "kind": "core", "clue": "classic", "globals": [], "tip": "C0 · 8 邻雷数"},
	# ---- C 类 · 线索型（C1~C7）----
	{"id": "4n", "name": "四邻", "kind": "clue", "clue": "4n", "globals": [], "tip": "C1"},
	{"id": "clock", "name": "钟点", "kind": "clue", "clue": "clock", "globals": [], "tip": "C2"},
	{"id": "hv", "name": "纵横分计", "kind": "clue", "clue": "hv", "globals": [], "tip": "C3"},
	{"id": "fr", "name": "首雷", "kind": "clue", "clue": "fr", "globals": [], "tip": "C4"},
	{"id": "loopruns", "name": "环游程", "kind": "clue", "clue": "loopruns", "globals": [], "tip": "C5"},
	{"id": "distsum", "name": "曼哈顿和", "kind": "clue", "clue": "distsum", "globals": [], "tip": "C6"},
	{"id": "sc", "name": "同色", "kind": "clue", "clue": "sc", "globals": [], "tip": "C7"},
	# ---- G 类 · 全局约束（G1~G7）----
	{"id": "mx", "name": "镜像", "kind": "global", "clue": "classic", "globals": ["mx"], "tip": "G1"},
	{"id": "rl", "name": "行锁", "kind": "global", "clue": "classic", "globals": ["rl"], "tip": "G2"},
	{"id": "pf", "name": "禁形", "kind": "global", "clue": "classic", "globals": ["pf"], "tip": "G3"},
	{"id": "qd", "name": "四象", "kind": "global", "clue": "classic", "globals": ["qd"], "tip": "G4"},
	{"id": "dt", "name": "骨牌", "kind": "global", "clue": "classic", "globals": ["dt"], "tip": "G5"},
	{"id": "ep", "name": "端点", "kind": "global", "clue": "classic", "globals": ["ep"], "tip": "G6"},
	{"id": "4c", "name": "守恒", "kind": "global", "clue": "classic", "globals": ["4c"], "tip": "G7"},
	# ---- 混合组合档（G+C，GDD 3.1.1 第 1 档）：已开放 ----
	# 注：早期版本这里标注「暂不开放」且依赖 MODES[i]["enabled"]=false 禁用，
	# 但实际条目里从未写过 enabled 字段 ⇒ 取默认值 true，一直是开放状态。
	# 注释与代码取其一：以代码现状为准（开放），注释同步更正，避免后来者误判。
	# parents = [父 G 类 id, 父 C 类 id]。刻意让 Gi+Ci 同序号配对，
	# 这样每条枝干上「中心 → C_i → 混合_i → G_i」四点共线，图谱不交叉。
	{"id": "mx_4n", "name": "镜像·四邻", "kind": "mixed", "clue": "4n", "globals": ["mx"], "parents": ["mx", "4n"], "tip": "G1+C1"},
	{"id": "rl_clock", "name": "行锁·钟点", "kind": "mixed", "clue": "clock", "globals": ["rl"], "parents": ["rl", "clock"], "tip": "G2+C2"},
	{"id": "pf_hv", "name": "禁形·纵横", "kind": "mixed", "clue": "hv", "globals": ["pf"], "parents": ["pf", "hv"], "tip": "G3+C3"},
	{"id": "qd_fr", "name": "四象·首雷", "kind": "mixed", "clue": "fr", "globals": ["qd"], "parents": ["qd", "fr"], "tip": "G4+C4"},
	{"id": "dt_loopruns", "name": "骨牌·环游程", "kind": "mixed", "clue": "loopruns", "globals": ["dt"], "parents": ["dt", "loopruns"], "tip": "G5+C5"},
	{"id": "ep_distsum", "name": "端点·曼哈顿", "kind": "mixed", "clue": "distsum", "globals": ["ep"], "parents": ["ep", "distsum"], "tip": "G6+C6"},
	{"id": "4c_sc", "name": "守恒·同色", "kind": "mixed", "clue": "sc", "globals": ["4c"], "parents": ["4c", "sc"], "tip": "G7+C7"},
]

# ===== 运行时状态 =====
var _nodes: Array[Button] = []       # 全部节点按钮（[0]=中心）
var _overlay: Control = null
var _popup: PanelContainer = null
var _popup_body: Control = null

var _mode_idx := -1                  # 当前弹窗所属模式（-1 = 未打开）
var _size_idx := 0
var _page := 0
var _selected := 0

# 弹窗内控件引用
var _size_btns: Array[Button] = []
var _frame: PanelContainer = null
var _grid_wrap: Control = null
var _grid: GridContainer = null
var _dots_box: VBoxContainer = null
var _stat_label: Label = null
var _play_btn: Button = null
var _title_label: Label = null

var _scroll_accum := 0.0

## 弹窗关闭动画期间禁止重开（原实现把 _overlay 立刻置 null，
## 动画的 0.22s 内再点节点就会叠出第二个弹窗）。
var _popup_closing := false

## 演示用「已通关」记录。**只在本次进程内有效、不落盘**。
## 历史 bug：这些记录原先直接写进真实的 ProgressStore（user://progress.json），
## 于是首次进入任何变体×尺寸都会永久留下一条「20.00 秒通关」的假数据，
## 还会连带解锁下一关——演示脚手架污染了玩家存档。
static var _mock_cleared: Dictionary = {}


func _ready() -> void:
	add_to_group("themed")
	ThemeManager.theme_changed.connect(_on_theme_changed)
	resized.connect(_layout_nodes)
	_build_graph()
	_consume_pending_focus()


## 终局页「下一关」交接过来的意图：直接展开对应变体×尺寸的关卡弹窗。
## 选关页默认就会把选中项定位到「最新解锁关卡」，所以玩家看到的就是下一关已被选中。
func _consume_pending_focus() -> void:
	var focus: Dictionary = LevelSequence.take_focus()
	if focus.is_empty():
		return
	var mode_id := str(focus.get("mode", ""))
	var want_size := int(focus.get("size", 0))
	for i in MODES.size():
		if str(MODES[i]["id"]) != mode_id:
			continue
		var size_i: int = SIZES.find(want_size)
		_open_popup(i)
		if size_i >= 0:
			_size_idx = size_i
			_ensure_mock()
			_refresh_popup()
		return


## 通关判定：真实存档 + 进程内演示记录。
func _is_cleared(key: String) -> bool:
	if bool(_mock_cleared.get(key, false)):
		return true
	return ProgressStore.is_cleared(key)


# ==================== 主界面：网状节点图 ====================

func _build_graph() -> void:
	# 顶部标题
	var title := Label.new()
	title.text = "选择关卡"
	title.add_theme_font_size_override("font_size", 30)
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 18
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	var hint := Label.new()
	hint.text = "点击节点选择模式　·　内圈 C 类线索型　中圈 G 类全局约束　外圈混合档"
	hint.add_theme_font_size_override("font_size", 16)
	hint.set_meta("secondary", true)
	hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	hint.offset_top = 56
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(hint)

	# 返回按钮（左上）
	var back := Button.new()
	back.text = "返回"
	back.focus_mode = Control.FOCUS_NONE
	back.custom_minimum_size = Vector2(96, 42)
	back.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	back.offset_left = 24
	back.offset_top = 18
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://ui/main_menu.tscn"))
	add_child(back)

	# 节点：中心 + C 类 + G 类 + 混合档
	for i in MODES.size():
		var m: Dictionary = MODES[i]
		var kind := String(m["kind"])
		var enabled := bool(m.get("enabled", true))
		var btn := Button.new()
		btn.text = "%s\n%s" % [m["name"], m["tip"]]
		btn.focus_mode = Control.FOCUS_NONE
		# 必须显式限字号：默认主题字号较大，中文名会把按钮撑到 140+ 宽，
		# 导致同一枝干上相邻节点（尤其近水平的枝干）矩形相交。
		btn.add_theme_font_size_override("font_size", 15 if kind == "mixed" else 16)
		if kind == "core":
			btn.custom_minimum_size = Vector2(150, 74)
		elif kind == "mixed":
			btn.custom_minimum_size = Vector2(112, 52)  # 混合档更小：挂在枝干中间不抢空间
		else:
			btn.custom_minimum_size = Vector2(126, 60)
		btn.pressed.connect(_open_popup.bind(i))
		add_child(btn)
		_nodes.append(btn)
		if enabled:
			UiTheme.bind_hover(btn, 1.08)  # 悬停缩放
		else:
			_style_node_locked(btn)  # 待开放：暗色、不放大

	_layout_nodes()
	_apply_theme()


## 布局：7 条径向枝干，每条「中心 → C 类 → 混合 → G 类」四点共线、互不交叉。
## C_i 与 G_i 同序号同角度，混合节点严格取两个父变体（parents=[G,C]）的连线中点，
## 因此混合天然挂在「合成它的两个变体」之间，且不会与任何节点重叠。
## 窗口缩放时由 resized 信号触发，重排后 _draw 自动重绘枝干。
func _layout_nodes() -> void:
	if _nodes.is_empty():
		return
	var cx := size.x * 0.5
	var cy := size.y * 0.5 + 16.0
	var avail := maxf(minf(size.x, size.y - 120.0), 360.0)
	var r_in := maxf(avail * 0.25, 150.0)    # C 类内圈
	var r_out := maxf(avail * 0.47, 285.0)   # G 类外圈（混合取两者中点）

	var center := Vector2(cx, cy)
	var pos_by_id := {}

	# 1) 中心：C0 经典基线
	for i in _nodes.size():
		if String(MODES[i]["kind"]) != "core":
			continue
		_nodes[i].position = center - _nodes[i].size * 0.5
		pos_by_id[String(MODES[i]["id"])] = center

	# 2) C 类内圈 / G 类外圈：按 MODES 声明顺序各自均匀布点（同序号 ⇒ 同角度）
	var c_count := 0
	var g_count := 0
	for m in MODES:
		var k := String((m as Dictionary)["kind"])
		if k == "clue":
			c_count += 1
		elif k == "global":
			g_count += 1
	var ci := 0
	var gi := 0
	for i in _nodes.size():
		var m: Dictionary = MODES[i]
		var kind := String(m["kind"])
		var ang := -PI * 0.5
		var r := 0.0
		if kind == "clue":
			ang += TAU * float(ci) / float(maxi(c_count, 1))
			r = r_in
			ci += 1
		elif kind == "global":
			ang += TAU * float(gi) / float(maxi(g_count, 1))
			r = r_out
			gi += 1
		else:
			continue
		var p := Vector2(cx + cos(ang) * r, cy + sin(ang) * r)
		_nodes[i].position = p - _nodes[i].size * 0.5
		pos_by_id[String(m["id"])] = p

	# 3) 混合：父 G 与父 C 的连线中点（严格共线，视觉上「两个变体合成一个混合」）
	for i in _nodes.size():
		var m: Dictionary = MODES[i]
		if String(m["kind"]) != "mixed":
			continue
		var ps: Array = m.get("parents", [])
		if ps.size() < 2:
			continue
		var a: Vector2 = pos_by_id.get(String(ps[0]), center)
		var b: Vector2 = pos_by_id.get(String(ps[1]), center)
		var mid := (a + b) * 0.5
		_nodes[i].position = mid - _nodes[i].size * 0.5
		pos_by_id[String(m["id"])] = mid
	queue_redraw()


## 绘制 7 条枝干：中心 → G 类（穿过同枝干的 C 类与混合节点）。
## 只画到外圈 G 类这一层，避免「中心辐射到全部 21 个节点」造成的线团。
func _draw() -> void:
	if _nodes.is_empty() or not is_instance_valid(_nodes[0]):
		return
	var line_col := ThemeManager.accent().darkened(0.42)
	var c: Button = _nodes[0]
	var cp := c.position + c.size * 0.5
	for i in range(1, _nodes.size()):
		var m: Dictionary = MODES[i]
		var b: Button = _nodes[i]
		if not is_instance_valid(b) or String(m["kind"]) != "global":
			continue
		var p := b.position + b.size * 0.5
		draw_line(cp, p, line_col, 2.0, true)
	# 非外圈节点（C 类 / 混合）画在枝干上的小圆点，标识层级
	for i in range(1, _nodes.size()):
		var m: Dictionary = MODES[i]
		if String(m["kind"]) == "global":
			continue
		var b: Button = _nodes[i]
		if not is_instance_valid(b):
			continue
		var p := b.position + b.size * 0.5
		var col := ThemeManager.text_secondary().darkened(0.25) if String(m["kind"]) == "mixed" else line_col
		draw_circle(p, 3.5, col)
	draw_circle(cp, 7.0, ThemeManager.accent().darkened(0.15))


# ==================== 弹窗 ====================

func _open_popup(mode_idx: int) -> void:
	if _overlay != null or _popup_closing:
		return
	_mode_idx = mode_idx
	_size_idx = 0
	_page = 0
	_selected = 0
	_scroll_accum = 0.0
	_ensure_mock()

	# 遮罩（点击外部关闭）
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_close_popup())
	_overlay.add_child(shade)

	# 弹窗主体（固定尺寸）
	_popup = PanelContainer.new()
	_popup.custom_minimum_size = POPUP_SIZE
	_popup.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_popup.position = -POPUP_SIZE * 0.5
	_popup.pivot_offset = POPUP_SIZE * 0.5
	_overlay.add_child(_popup)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	_popup.add_child(root)

	# 标题栏
	var head := HBoxContainer.new()
	head.custom_minimum_size = Vector2(0, 58)
	head.add_theme_constant_override("margin_left", 22)
	head.add_theme_constant_override("margin_right", 18)
	root.add_child(head)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 24)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title_label)

	var close := Button.new()
	close.text = "✕"
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size = Vector2(40, 40)
	close.set_meta("std_btn", true)
	close.pressed.connect(_close_popup)
	head.add_child(close)

	# 内容区：左（棋盘框） + 右（面板）
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	body.add_theme_constant_override("margin_left", 18)
	body.add_theme_constant_override("margin_right", 18)
	body.add_theme_constant_override("margin_bottom", 18)
	root.add_child(body)
	_popup_body = body

	_build_left(body)
	_build_right(body)

	_refresh_popup()

	# 入场动画：缩放 + 淡入
	_popup.scale = Vector2(0.92, 0.92)
	_popup.modulate.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_popup, "scale", Vector2.ONE, ANIM).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_popup, "modulate:a", 1.0, ANIM)
	_apply_theme()


## 左侧：棋盘框（尺寸选择栏 + 关卡网格 + 分页圆点），整体蓝色高亮发光。
func _build_left(parent: Node) -> void:
	_frame = PanelContainer.new()
	_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_frame.custom_minimum_size = Vector2(700, 0)
	# PanelContainer 默认 mouse_filter=IGNORE，不设 STOP 收不到滚轮事件
	_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	_frame.gui_input.connect(_on_frame_input)
	parent.add_child(_frame)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	vbox.add_theme_constant_override("margin_left", 16)
	vbox.add_theme_constant_override("margin_right", 16)
	vbox.add_theme_constant_override("margin_top", 14)
	vbox.add_theme_constant_override("margin_bottom", 16)
	_frame.add_child(vbox)

	# 尺寸选择栏
	var size_bar := HBoxContainer.new()
	size_bar.add_theme_constant_override("separation", 10)
	vbox.add_child(size_bar)

	for i in SIZES.size():
		var s: int = SIZES[i]
		var b := Button.new()
		b.text = "%d×%d" % [s, s]
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(104, 40)
		b.pressed.connect(_on_size_selected.bind(i))
		size_bar.add_child(b)
		_size_btns.append(b)
		UiTheme.bind_hover(b, 1.04)

	# 网格区（网格 + 右侧分页圆点）
	var grid_row := HBoxContainer.new()
	grid_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid_row.add_theme_constant_override("separation", 12)
	vbox.add_child(grid_row)

	_grid_wrap = Control.new()
	_grid_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid_wrap.clip_contents = true
	grid_row.add_child(_grid_wrap)

	_grid = GridContainer.new()
	_grid.columns = GRID_COLS
	_grid.add_theme_constant_override("h_separation", 14)
	_grid.add_theme_constant_override("v_separation", 14)
	_grid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_grid_wrap.add_child(_grid)

	_dots_box = VBoxContainer.new()
	_dots_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_dots_box.add_theme_constant_override("separation", 10)
	_dots_box.custom_minimum_size = Vector2(24, 0)
	grid_row.add_child(_dots_box)


## 右侧面板：通关统计 + 继续/开始游戏按钮。
func _build_right(parent: Node) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(280, 0)
	parent.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	vbox.add_theme_constant_override("margin_left", 18)
	vbox.add_theme_constant_override("margin_right", 18)
	vbox.add_theme_constant_override("margin_top", 18)
	vbox.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(vbox)

	var cap := Label.new()
	cap.text = "通关统计"
	cap.add_theme_font_size_override("font_size", 18)
	vbox.add_child(cap)

	_stat_label = Label.new()
	_stat_label.add_theme_font_size_override("font_size", 26)
	vbox.add_child(_stat_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	_play_btn = Button.new()
	_play_btn.custom_minimum_size = Vector2(0, 54)
	_play_btn.focus_mode = Control.FOCUS_NONE
	_play_btn.set_meta("std_btn", true)
	_play_btn.pressed.connect(_on_play)
	vbox.add_child(_play_btn)
	UiTheme.bind_hover(_play_btn, 1.03)


func _close_popup() -> void:
	if _overlay == null or _popup_closing:
		return
	var ov := _overlay
	_popup_closing = true
	_overlay = null
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_popup, "scale", Vector2(0.92, 0.92), ANIM)
	tw.tween_property(_popup, "modulate:a", 0.0, ANIM)
	tw.chain().tween_callback(func():
		ov.queue_free()
		_popup_closing = false)
	_size_btns.clear()
	_mode_idx = -1


# ==================== 弹窗内容刷新 ====================

## 该变体在该尺寸下是否可生成（R07 固定雷数下的数学可行性）。
## v2.9.3 起走 RuleFeasibility 真值查询（CP-SAT is_feasible + 缓存）——不再手写
## UNSAT 规则表（手写表曾漏掉 rl 6×6 / qd 6×6、8×8 导致玩家选中后永远转圈；
## 且新增/Mod 变体都需要同步手改，必然再漏）。真值查询对任何变体自动正确。
func _mode_feasible(mode: Dictionary, size: int) -> bool:
	# v3.0：候选雷数回退——标准值不可行但候选可行时，该尺寸仍可玩（生成侧自动用回退雷数）。
	# 全候选不可行才禁用（如 mx+rl 6×6：镜像+行锁在全部候选雷数下均矛盾）。
	return int(RuleFeasibility.resolve_mines(str(mode["clue"]), mode.get("globals", []), size)["mines"]) >= 0


func _refresh_popup() -> void:
	if _mode_idx < 0 or _grid == null:
		return
	var m: Dictionary = MODES[_mode_idx]
	# 当前尺寸对该变体不可行 → 自动切到最近的可行尺寸（避免「选中即必失败」状态）
	if not _mode_feasible(m, SIZES[_size_idx]):
		for i in SIZES.size():
			var cand: int = ( _size_idx + i ) % SIZES.size()
			if _mode_feasible(m, SIZES[cand]):
				_size_idx = cand
				break
	_title_label.text = "%s · %d×%d" % [m["name"], SIZES[_size_idx], SIZES[_size_idx]]

	# 尺寸按钮高亮 + 可行性禁用（不可行组合按钮置灰 + tooltip 说明原因，点不了）
	for i in _size_btns.size():
		_style_choice(_size_btns[i], i == _size_idx)
		var ok := _mode_feasible(m, SIZES[i])
		_size_btns[i].disabled = not ok
		_size_btns[i].tooltip_text = "" if ok else \
			"该变体在 %d×%d（%d 雷）下数学上无解——请换尺寸或换变体" % [
					SIZES[i], SIZES[i], LevelSequence.mine_count(SIZES[i])]
	_style_frame()

	# 分页：定位到「最新解锁关卡」所在页（切换尺寸时重置）
	var page_count := _page_count()
	_page = clampi(_page, 0, page_count - 1)
	_selected = _latest_unlocked()
	_page = floori(float(_selected) / float(PAGE_SIZE))

	_rebuild_grid()
	_rebuild_dots()
	_refresh_stat()


func _rebuild_grid() -> void:
	for c in _grid.get_children():
		c.queue_free()
	var start := _page * PAGE_SIZE
	var end := mini(start + PAGE_SIZE, LEVELS_PER_SET)
	for i in range(start, end):
		_grid.add_child(_make_tile(i))
	# 关卡不足时网格留白：补足空占位，保证方块尺寸统一、从左到右从上到下排列
	var shown := end - start
	for _k in range(PAGE_SIZE - shown):
		var ph := Control.new()
		ph.custom_minimum_size = TILE
		_grid.add_child(ph)
	# 内容淡入
	_grid_wrap.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_grid_wrap, "modulate:a", 1.0, ANIM)


func _make_tile(idx: int) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = TILE
	btn.focus_mode = Control.FOCUS_NONE
	var unlocked := _is_unlocked(idx)
	var cleared := _is_cleared(_level_key(idx))
	btn.text = str(idx + 1)
	if cleared:
		btn.text += "  ✓"
	elif not unlocked:
		btn.text = "🔒"
	btn.disabled = not unlocked
	btn.set_meta("idx", idx)  # 选中态刷新需要回读关卡序号
	btn.pressed.connect(_on_tile_pressed.bind(idx))
	_style_tile(btn, idx == _selected, cleared)
	UiTheme.bind_hover(btn, 1.05)
	return btn


func _rebuild_dots() -> void:
	for c in _dots_box.get_children():
		c.queue_free()
	var n := _page_count()
	for i in n:
		var d := Button.new()
		d.custom_minimum_size = Vector2(14, 14)
		d.focus_mode = Control.FOCUS_NONE
		d.pressed.connect(_go_page.bind(i))
		_style_dot(d, i == _page)
		_dots_box.add_child(d)


func _refresh_stat() -> void:
	var cleared := 0
	for i in LEVELS_PER_SET:
		if _is_cleared(_level_key(i)):
			cleared += 1
	_stat_label.text = "已通关 %d / %d" % [cleared, LEVELS_PER_SET]
	# 按钮：选中最新解锁关卡 → 继续游戏；手选其他 → 开始游戏；未开放变体 → 禁用
	if _mode_enabled():
		_play_btn.disabled = false
		_play_btn.text = "继续游戏" if _selected == _latest_unlocked() else "开始游戏"
	else:
		_play_btn.disabled = true
		_play_btn.text = "尚未开放"


func _go_page(p: int) -> void:
	var n := _page_count()
	var np := clampi(p, 0, n - 1)
	if np == _page:
		return
	_page = np
	_scroll_accum = 0.0
	_rebuild_grid()
	_rebuild_dots()


func _on_size_selected(i: int) -> void:
	if i == _size_idx:
		return
	_size_idx = i
	_page = 0
	_scroll_accum = 0.0
	_ensure_mock()
	_refresh_popup()  # 内部会重置分页并定位最新解锁关卡


func _on_tile_pressed(idx: int) -> void:
	if not _is_unlocked(idx):
		return
	_selected = idx
	for c in _grid.get_children():
		if c is Button:
			var i := int(c.get_meta("idx", -1))
			_style_tile(c, i == _selected, _is_cleared(_level_key(i)))
	_refresh_stat()


# ==================== 数据 / 进度 ====================

## 当前模式是否开放关卡（混合档 enabled=false：弹窗可看，但不生成/进入关卡）。
func _mode_enabled() -> bool:
	if _mode_idx < 0:
		return false
	return bool(MODES[_mode_idx].get("enabled", true))


func _level_key(idx: int) -> String:
	# 缓存/进度键不掺雷数：同 mode×size 的雷数由 resolve_mines 唯一确定（候选回退是
	# 确定性判定 + 缓存），且回退组合在旧版（固定标准雷数）下本就生成不出文件
	#（UNSAT），不存在「旧缓存与新雷数撞键」的歧义——无需为候选回退改键结构。
	var m: Dictionary = MODES[_mode_idx]
	return "gen://%s/%d/%d" % [m["id"], SIZES[_size_idx], idx]


func _level_seed(idx: int) -> int:
	# 确定性种子：同模式+尺寸+序号必得同一盘。
	# v3.1：改用模式 id / 尺寸边长的稳定哈希而非数组下标——插入新变体/尺寸
	# 不再改变所有后续模式的种子（「同 seed 同盘」承诺不因 MODES/SIZES 顺序变化失效）。
	# 雷数不掺入种子（GDD §8.1）：它由 mode×size 经候选回退唯一确定，见 _level_key 注释。
	return hash("%s|%d|%d" % [str(MODES[_mode_idx]["id"]), SIZES[_size_idx], idx])


func _page_count() -> int:
	return maxi(1, ceili(float(LEVELS_PER_SET) / float(PAGE_SIZE)))


func _mine_count() -> int:
	# v3.0 候选雷数回退（GDD 终版 §8.1）：走 RuleFeasibility 真值解析——标准雷数与
	# 守恒算子互斥时自动回退候选列表下一项（如 qd 8×8：26 非 4 倍数 → 回退 24）。
	# 结果带缓存（同 mode×size 仅首次走 CP-SAT），与 _mode_feasible 共享同一批查询。
	# 全候选不可行返回 -1（正常流程被 _refresh_popup 的尺寸禁用 + _on_play 防御拦下，
	# 不会走到生成）。
	var m: Dictionary = MODES[_mode_idx]
	return int(RuleFeasibility.resolve_mines(
			String(m["clue"]), m.get("globals", []), SIZES[_size_idx])["mines"])


## 最新解锁关卡：第一个未通关的关卡；全部通关则为最后一关。
func _latest_unlocked() -> int:
	for i in LEVELS_PER_SET:
		if not _is_cleared(_level_key(i)):
			return i
	return LEVELS_PER_SET - 1


func _is_unlocked(idx: int) -> bool:
	if idx == 0:
		return true
	return _is_cleared(_level_key(idx - 1))


## 演示预设：首次进入某套时预置前 MOCK_CLEARED 关为「已通关」（便于演示解锁/继续流程）。
## **只写内存字典，不落盘**——写进 ProgressStore 等于往玩家真存档里塞假成绩。
func _ensure_mock() -> void:
	if _mode_idx < 0:
		return
	for i in LEVELS_PER_SET:
		if _is_cleared(_level_key(i)):
			return
	for i in mini(MOCK_CLEARED, LEVELS_PER_SET):
		_mock_cleared[_level_key(i)] = true


# ==================== 进入对局 ====================

## 生成尝试总数（与原 generate_with_rules(attempts=50) 口径一致）。
const GEN_ATTEMPTS := 50
var _gen_cancel := false


func _on_play() -> void:
	if _play_btn == null or _mode_idx < 0:
		return
	var m: Dictionary = MODES[_mode_idx]
	var s: int = SIZES[_size_idx]
	_play_btn.disabled = true
	_play_btn.text = "校验中…"
	await get_tree().process_frame
	# 0) 防御：全候选雷数均不可行（正常流程已被尺寸按钮禁用拦下）→ 直接拒绝，不进生成。
	#    （resolve_mines 带缓存，此处与 _mine_count/_mode_feasible 共享查询结果。）
	var rr := RuleFeasibility.resolve_mines(String(m["clue"]), m.get("globals", []), s)
	if int(rr["mines"]) < 0:
		_play_btn.disabled = false
		_refresh_stat()
		UiToast.popup(self, "该变体在 %d×%d 的全部候选雷数下数学无解——请换尺寸或换变体" % [s, s])
		return
	# 候选雷数回退提示（非阻断 toast，GDD 终版 §8.1 口径）：标准雷数与守恒算子互斥时，
	# 生成器自动改用候选列表下一项——明确告知玩家，不打断流程。
	if not bool(rr["standard"]):
		UiToast.popup(self, "该组合在 %d 雷下不可行，已回退 %d 雷（候选列表自动选择）" % [
			LevelSequence.mine_count(s), int(rr["mines"])])
	# 1) 可行性预筛（毫秒级）：规则冗余/矛盾、雷数不可达 → 立即拒绝，绝不暴力生成
	var pre := PuzzleGenerator.precheck_rules(String(m["clue"]), m["globals"], Vector2i(s, s), _mine_count())
	if not pre["ok"]:
		_play_btn.disabled = false
		_refresh_stat()
		UiToast.popup(self, str(pre["reason"]))
		return
	# 2) 组合可行，进入生成。
	#    生成是同步阻塞的（CP-SAT 全管线单次调用不可中断），原先只能干等到它跑完——
	#    现在把重试循环提到 UI 层：每次 attempt 之间让出一帧，界面可响应「取消」。
	var path := await _ensure_level_file_async(_selected)
	if path == "":
		_play_btn.disabled = false
		_refresh_stat()
		UiToast.popup(self, "已取消生成" if _gen_cancel else \
				"该组合可行，但本关未能生成序贯可解布局，请换一关或换尺寸")
		return
	if GameSession.start_level(path):
		get_tree().change_scene_to_file("res://ui/board_view.tscn")
	else:
		_play_btn.disabled = false
		_refresh_stat()
		UiToast.popup(self, "关卡加载失败")


## 生成并缓存关卡文件（已存在则直接复用，避免重复生成）。
## 异步版：attempt 之间让帧 + 可被玩家取消。
func _ensure_level_file_async(idx: int) -> String:
	var m: Dictionary = MODES[_mode_idx]
	var s: int = SIZES[_size_idx]
	# 兜底防御（正常已被 _refresh_popup 的尺寸禁用拦下）：数学不可行组合直接拦截，
	# 不进入生成器白耗 50 次 attempt（每次都会 UNSAT 返回空）。
	if not _mode_feasible(m, s):
		push_warning("关卡选择：变体 %s 在 %d×%d（全部候选雷数）下数学不可行，已拦截生成" % [
			str(m["id"]), s, s])
		return ""
	var path := LevelSequence.level_path(str(m["id"]), s, idx)
	if FileAccess.file_exists(path):
		return path

	DirAccess.make_dir_recursive_absolute(LevelSequence.GEN_DIR)
	var dlg := _open_gen_dialog(s)
	var deadline := Time.get_ticks_msec() + _gen_timeout(s)
	var gen := PuzzleGenerator.new()
	var out := ""
	var started_ms := Time.get_ticks_msec()
	for attempt in GEN_ATTEMPTS:
		await get_tree().process_frame
		if _gen_cancel:
			break
		var used_sec: int = (Time.get_ticks_msec() - started_ms) / 1000
		dlg.get_meta("sub").text = "已用时 %d 秒（上限 %d 秒）" % [used_sec, _gen_timeout(s) / 1000]
		var remain: int = deadline - Time.get_ticks_msec()
		if remain <= 0:
			break
		# 单次 attempt + 外层换种子：首尝试的种子派生与原来完全一致
		# （内部 attempts=1 ⇒ _derive_seed(seed, 0)），保证既有关卡文件复现语义不变。
		var level: Dictionary = gen.generate_with_rules(
			String(m["clue"]), m["globals"], Vector2i(s, s), _mine_count(),
			_level_seed(idx) + attempt, 0, 1, null, remain)
		if level.is_empty():
			continue
		# 记录生成参数，便于追溯复现
		level["gen"] = {"mode": m["id"], "size": s, "index": idx, "seed": _level_seed(idx)}
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			break
		f.store_string(JSON.stringify(level, "  "))
		f.close()
		out = path
		break
	_close_gen_dialog(dlg)
	_gen_cancel = false
	return out


## 生成进度弹窗：明确告诉玩家「程序在忙」，并给取消出口。
func _open_gen_dialog(size: int) -> PopupPanel:
	_gen_cancel = false
	var dlg := PopupPanel.new()
	dlg.exclusive = true
	var panel := PanelContainer.new()
	dlg.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(320, 0)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "正在生成 %d×%d 关卡" % [size, size]
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var sub := Label.new()
	sub.add_theme_font_size_override("font_size", 16)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.text = "大概需要 %d 秒，复杂变体会更久" % _estimate_gen_seconds(size)
	vb.add_child(sub)

	var cancel := Button.new()
	cancel.text = "取消"
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.custom_minimum_size = Vector2(0, 44)
	cancel.pressed.connect(func():
		_gen_cancel = true
		dlg.hide())
	vb.add_child(cancel)

	dlg.set_meta("sub", sub)
	add_child(dlg)
	dlg.hide()   # Window 默认 visible=true
	dlg.popup_centered()
	return dlg


func _close_gen_dialog(dlg: PopupPanel) -> void:
	if dlg != null and is_instance_valid(dlg):
		dlg.queue_free()


# ==================== 滚轮翻页 ====================

func _on_frame_input(ev: InputEvent) -> void:
	if not (ev is InputEventMouseButton) or not ev.pressed:
		return
	var dir := 0.0
	if ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		dir = 1.0
	elif ev.button_index == MOUSE_BUTTON_WHEEL_UP:
		dir = -1.0
	else:
		return
	var factor := float((ev as InputEventMouseButton).factor)
	if factor <= 0.0:
		factor = 1.0
	_scroll_accum += dir * factor
	if abs(_scroll_accum) >= SCROLL_THRESHOLD:
		var d := 1 if _scroll_accum > 0 else -1
		_scroll_accum = 0.0
		_go_page(_page + d)
	else:
		_bounce(dir * factor)


## 轻滚回弹：网格轻微位移后弹回，给「翻页未触发」一点触感反馈。
func _bounce(dir: float) -> void:
	if _grid_wrap == null:
		return
	if _grid_wrap.has_meta("bounce_tw"):
		var old: Tween = _grid_wrap.get_meta("bounce_tw")
		if old != null and old.is_valid():
			old.kill()
	_grid_wrap.position.y = clampf(dir * 10.0, -16.0, 16.0)
	var tw := create_tween()
	tw.tween_property(_grid_wrap, "position:y", 0.0, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_grid_wrap.set_meta("bounce_tw", tw)


# ==================== 样式 / 主题 ====================

## 棋盘框：选中尺寸后整体蓝色高亮 + 微弱发光。
func _style_frame() -> void:
	if _frame == null:
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = ThemeManager.card().darkened(0.25)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2)
	sb.border_color = ThemeManager.accent()
	sb.shadow_color = Color(ThemeManager.accent().r, ThemeManager.accent().g, ThemeManager.accent().b, 0.35)
	sb.shadow_size = 14
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	_frame.add_theme_stylebox_override("panel", sb)


## 待开放节点（混合档）：暗色弱化，与可玩变体在视觉上区分。
func _style_node_locked(b: Button) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = ThemeManager.card().darkened(0.38)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(1)
	sb.border_color = ThemeManager.text_secondary().darkened(0.45)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_color_override("font_color", ThemeManager.text_secondary())


## 尺寸选项按钮：选中态蓝色高亮。
func _style_choice(b: Button, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(2 if active else 1)
	if active:
		sb.bg_color = ThemeManager.accent().darkened(0.55)
		sb.border_color = ThemeManager.accent()
	else:
		sb.bg_color = ThemeManager.card()
		sb.border_color = ThemeManager.grid_line()
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_color_override("font_color", ThemeManager.text())


## 关卡方块：选中蓝色高亮；已通关绿色调；未解锁暗色。
func _style_tile(b: Button, selected: bool, cleared: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(2 if selected else 1)
	if selected:
		sb.bg_color = ThemeManager.accent().darkened(0.5)
		sb.border_color = ThemeManager.accent()
	elif cleared:
		sb.bg_color = ThemeManager.safe().darkened(0.55)
		sb.border_color = ThemeManager.safe().darkened(0.2)
	else:
		sb.bg_color = ThemeManager.card()
		sb.border_color = ThemeManager.grid_line()
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_color_override("font_color", ThemeManager.text())
	# 禁用态必须用 font_disabled_color（font_color 对 disabled 无效）
	b.add_theme_color_override("font_disabled_color", ThemeManager.text_secondary().darkened(0.25))


func _style_dot(d: Button, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(7)
	sb.bg_color = ThemeManager.accent() if active else ThemeManager.text_secondary().darkened(0.35)
	sb.set_border_width_all(0)
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	d.add_theme_stylebox_override("normal", sb)
	d.add_theme_stylebox_override("hover", sb)
	d.add_theme_stylebox_override("pressed", sb)


func _apply_theme() -> void:
	for n in get_children():
		if n is Label:
			var col := ThemeManager.text_secondary() if bool(n.get_meta("secondary", false)) else ThemeManager.text()
			n.add_theme_color_override("font_color", col)
		elif n is Button:
			UiTheme.style_button(n)
	if _overlay != null:
		_apply_popup_theme(_overlay)
	queue_redraw()


## 弹窗内主题：Label 直接刷色；Button 只刷新「标准按钮」（标记 std_btn）。
## 关卡方块 / 尺寸选项 / 分页圆点是自定义样式，由 _refresh_popup 重建；
## 若在此遍历覆盖，会把它们打回默认外观（选中高亮、圆点全失效）。
func _apply_popup_theme(root: Node) -> void:
	for c in root.get_children():
		if c is Label:
			c.add_theme_color_override("font_color", ThemeManager.text())
		elif c is Button and bool(c.get_meta("std_btn", false)):
			UiTheme.style_button(c)
		if c.get_child_count() > 0 and not (c is Button):
			_apply_popup_theme(c)


## 主题切换去抖（v3.1）：ThemeManager 一次切换广播 ~10 次 theme_changed，而
## _refresh_popup 会重跑 4 次 RuleFeasibility 查询（弹窗开着时 = 40 次 CP-SAT 调用
## + 网格整体重建闪烁）。300ms 去抖把多次广播合并为 1 次刷新，最终状态一致。
var _theme_refresh_pending := false

func _on_theme_changed() -> void:
	_apply_theme()
	if _mode_idx < 0 or _theme_refresh_pending:
		return
	_theme_refresh_pending = true
	await get_tree().create_timer(0.3).timeout
	_theme_refresh_pending = false
	if _mode_idx >= 0:
		_refresh_popup()


# ==================== 杂项 ====================
# toast 统一走 UiToast（原先此处与 main_menu 各实现了一份完全相同的 Label+Timer）。
