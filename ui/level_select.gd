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
const LEVELS_PER_SET := 3       # 每套关卡数（每个变体/混合变体各生成 3 关）
const PAGE_SIZE := 20           # 一页最多 20 关
const GRID_COLS := 5            # 网格 5 列
const SIZES: Array = [5, 6, 7, 8, 9]
## 每尺寸雷数（约 40% 密度：10/25=40%、14/36=38.9%、20/49=40.8%、26/64=40.6%、32/81=39.5%）。
const MINE_COUNTS := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
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
	# ---- 混合组合档（G+C，GDD 3.1.1 第 1 档）：暂不开放关卡 ----
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


func _ready() -> void:
	add_to_group("themed")
	ThemeManager.theme_changed.connect(_on_theme_changed)
	resized.connect(_layout_nodes)
	_build_graph()


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
	if _overlay != null:
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
	if _overlay == null:
		return
	var ov := _overlay
	_overlay = null
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_popup, "scale", Vector2(0.92, 0.92), ANIM)
	tw.tween_property(_popup, "modulate:a", 0.0, ANIM)
	tw.chain().tween_callback(ov.queue_free)
	_size_btns.clear()
	_mode_idx = -1


# ==================== 弹窗内容刷新 ====================

## 该变体在该尺寸下是否可生成（R07 固定雷数下的数学可行性）。
## v2.9.3 起走 RuleFeasibility 真值查询（CP-SAT is_feasible + 缓存）——不再手写
## UNSAT 规则表（手写表曾漏掉 rl 6×6 / qd 6×6、8×8 导致玩家选中后永远转圈；
## 且新增/Mod 变体都需要同步手改，必然再漏）。真值查询对任何变体自动正确。
func _mode_feasible(mode: Dictionary, size: int) -> bool:
	var mines: int = maxi(1, int(MINE_COUNTS.get(size, int(float(size * size) * 0.4))))
	return RuleFeasibility.query(str(mode["clue"]), mode.get("globals", []), size, mines)


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
			"该变体在 %d×%d（%d 雷）下数学上无解——请换尺寸或换变体" % [SIZES[i], SIZES[i], int(MINE_COUNTS.get(SIZES[i], 0))]
	_style_frame()

	# 分页：定位到「最新解锁关卡」所在页（切换尺寸时重置）
	var page_count := _page_count()
	_page = clampi(_page, 0, page_count - 1)
	_selected = _latest_unlocked()
	_page = _selected / PAGE_SIZE

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
	var cleared := ProgressStore.is_cleared(_level_key(idx))
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
		if ProgressStore.is_cleared(_level_key(i)):
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
			_style_tile(c, i == _selected, ProgressStore.is_cleared(_level_key(i)))
	_refresh_stat()


# ==================== 数据 / 进度 ====================

## 当前模式是否开放关卡（混合档 enabled=false：弹窗可看，但不生成/进入关卡）。
func _mode_enabled() -> bool:
	if _mode_idx < 0:
		return false
	return bool(MODES[_mode_idx].get("enabled", true))


func _level_key(idx: int) -> String:
	var m: Dictionary = MODES[_mode_idx]
	return "gen://%s/%d/%d" % [m["id"], SIZES[_size_idx], idx]


func _level_seed(idx: int) -> int:
	# 确定性种子：同模式+尺寸+序号必得同一盘
	return (_mode_idx + 1) * 100000 + (_size_idx + 1) * 1000 + idx


func _page_count() -> int:
	return maxi(1, ceili(float(LEVELS_PER_SET) / float(PAGE_SIZE)))


func _mine_count() -> int:
	# 每尺寸固定雷数（约 40% 密度，见 MINE_COUNTS）；未列出的尺寸回退 40%。
	var s: int = SIZES[_size_idx]
	return maxi(1, int(MINE_COUNTS.get(s, int(float(s * s) * 0.4))))


## 最新解锁关卡：第一个未通关的关卡；全部通关则为最后一关。
func _latest_unlocked() -> int:
	for i in LEVELS_PER_SET:
		if not ProgressStore.is_cleared(_level_key(i)):
			return i
	return LEVELS_PER_SET - 1


func _is_unlocked(idx: int) -> bool:
	if idx == 0:
		return true
	return ProgressStore.is_cleared(_level_key(idx - 1))


## 模拟存档：首次进入某套时预置前 MOCK_CLEARED 关为已通关（便于演示解锁/继续流程）。
func _ensure_mock() -> void:
	if _mode_idx < 0:
		return
	for i in LEVELS_PER_SET:
		if ProgressStore.is_cleared(_level_key(i)):
			return
	for i in mini(MOCK_CLEARED, LEVELS_PER_SET):
		ProgressStore.record_clear(_level_key(i), 20.0 + float(i) * 3.0)


# ==================== 进入对局 ====================

func _on_play() -> void:
	if _play_btn == null or _mode_idx < 0:
		return
	var m: Dictionary = MODES[_mode_idx]
	var s: int = SIZES[_size_idx]
	_play_btn.disabled = true
	_play_btn.text = "校验中…"
	await get_tree().process_frame
	# 1) 可行性预筛（毫秒级）：规则冗余/矛盾、雷数不可达 → 立即拒绝，绝不暴力生成
	var pre := PuzzleGenerator.precheck_rules(String(m["clue"]), m["globals"], Vector2i(s, s), _mine_count())
	if not pre["ok"]:
		_play_btn.disabled = false
		_refresh_stat()
		_toast(str(pre["reason"]))
		return
	# 2) 组合可行，进入生成（仍可能换 seed 尝试，但不会对 UNSAT 组合白跑）。
	#    生成是同步阻塞的单次调用（CP-SAT 全管线），无法中途刷新进度——给出按尺寸的
	#    诚实预估，避免玩家以为卡死（9×9 单关实测 ~9~15s）。
	_play_btn.text = "生成中…（预计约 %d 秒）" % _estimate_gen_seconds(s)
	await get_tree().process_frame
	var path := _ensure_level_file(_selected)
	if path == "":
		_play_btn.disabled = false
		_refresh_stat()
		_toast("该组合可行，但本关未能生成序贯可解布局，请换一关或换尺寸")
		return
	if GameSession.start_level(path):
		get_tree().change_scene_to_file("res://ui/board_view.tscn")
	else:
		_play_btn.disabled = false
		_refresh_stat()
		_toast("关卡加载失败")


## 生成并缓存关卡文件（已存在则直接复用，避免重复生成）。
func _ensure_level_file(idx: int) -> String:
	var dir := "user://gen_levels"
	DirAccess.make_dir_recursive_absolute(dir)
	var m: Dictionary = MODES[_mode_idx]
	# 兜底防御（正常已被 _refresh_popup 的尺寸禁用拦下）：数学不可行组合直接拦截，
	# 不进入生成器白耗 50 次 attempt（每次都会 UNSAT 返回空）。
	if not _mode_feasible(m, SIZES[_size_idx]):
		push_warning("关卡选择：变体 %s 在 %d×%d（R07 雷数）下数学不可行，已拦截生成" % [
			str(m["id"]), SIZES[_size_idx], SIZES[_size_idx]])
		return ""
	var path := "%s/%s_%d_%d.json" % [dir, m["id"], SIZES[_size_idx], idx]
	if FileAccess.file_exists(path):
		return path
	var s: int = SIZES[_size_idx]
	var gen := PuzzleGenerator.new()
	var level: Dictionary = gen.generate_with_rules(
		String(m["clue"]), m["globals"], Vector2i(s, s), _mine_count(), _level_seed(idx),
		0, 50, null, _gen_timeout(s))
	if level.is_empty():
		return ""
	# 记录生成参数，便于追溯复现
	level["gen"] = {"mode": m["id"], "size": s, "index": idx, "seed": _level_seed(idx)}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(level, "  "))
	f.close()
	return path


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


func _on_theme_changed() -> void:
	_apply_theme()
	if _mode_idx >= 0:
		_refresh_popup()


# ==================== 杂项 ====================

func _toast(msg: String) -> void:
	var lb := Label.new()
	lb.text = msg
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", 18)
	lb.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	lb.offset_top = -56
	lb.custom_minimum_size = Vector2(0, 32)
	add_child(lb)
	lb.add_theme_color_override("font_color", ThemeManager.danger())
	var timer := Timer.new()
	timer.wait_time = 2.0
	timer.one_shot = true
	timer.timeout.connect(lb.queue_free)
	timer.timeout.connect(timer.queue_free)
	add_child(timer)
	timer.start()
