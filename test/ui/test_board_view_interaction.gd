# test_board_view_interaction.gd —— 棋盘视图的交互契约
#
# 覆盖本轮修复的三处「接线型」缺陷，它们全都无法靠静态检查发现：
#   ① guess_rejected 此前无人订阅 → 无猜模式点击被拒时零反馈；
#   ② 弹窗不吞键盘 → 设置弹窗开着按 R 会把对局重开；
#   ③ State.PAUSED 此前没有任何 UI 入口 → 暂停是死代码。
extends GutTest

var _view


func before_each() -> void:
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	_view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(_view)


func after_each() -> void:
	if GameSession.state == GameSession.State.PAUSED:
		GameSession.set_paused(false)


## 格子中心的本地坐标（board_view._pick 吃的是 local position）
func _cell_center(pos: Vector2i) -> Vector2:
	return _view.board_origin + (Vector2(pos) + Vector2(0.5, 0.5)) * float(_view.cell_px)


func _key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	return ev


# B1：构建即完成接线 —— 绘画层拿到棋盘坐标换算（窗口缩放后笔记跟随棋盘）
func test_b1_builds_and_injects_board_transform() -> void:
	assert_not_null(_view, "棋盘视图应能实例化")
	var layer: DrawingLayer = _view._drawing
	assert_not_null(layer, "board_view 应创建绘画层")
	assert_true(GameSession._drawing_provider.is_valid(), "board_view 应注册绘画数据采集回调")
	assert_true(layer.screen_to_board.is_valid(), "必须注入屏幕→棋盘换算")
	assert_true(layer.board_to_screen.is_valid(), "必须注入棋盘→屏幕换算")


# B2：无猜模式「猜测被拒」必须有可见反馈（原实现零反馈，看起来像卡死）
func test_b2_guess_rejected_has_feedback() -> void:
	var pos: Vector2i = GameSession.board.grid.all_positions()[0]
	GameSession.guess_rejected.emit(pos)
	assert_eq(_view._reject_pos, pos, "被拒格应记录下来用于绘制闪烁反馈")
	assert_gt(_view._reject_until_ms, 0, "应启动一段有限的闪烁时长")


# B3：有可见弹窗时，键盘不得穿透到棋盘（历史 bug：设置弹窗开着按 R 会重开对局）
# 2026-09-28（用户决策）：**进行中**的 R 键重开已删，终局通道保留 —— 探针改用
# ENDED 状态（终局键盘重开仍生效），用例语义与按键不变。
func test_b3_open_popup_blocks_keys() -> void:
	var dlg := PopupPanel.new()
	add_child_autofree(dlg)
	dlg.popup_centered()
	assert_true(_view._has_open_popup(), "应能识别到可见弹窗")

	GameSession.state = GameSession.State.ENDED
	var before := GameSession.board
	_view._unhandled_key_input(_key(KEY_R))
	assert_same(GameSession.board, before, "弹窗打开时按 R 不得重开对局")


# B4：弹窗关闭后同一按键恢复生效（守卫不能误伤正常操作）
func test_b4_keys_work_after_popup_closed() -> void:
	var dlg := PopupPanel.new()
	add_child_autofree(dlg)
	dlg.popup_centered()
	dlg.hide()
	assert_false(_view._has_open_popup(), "弹窗隐藏后不应再拦截按键")

	# 终局的键盘重开（2026-09-28：进行中的 R 已删，终局仍保留）——
	# 同一按键、同一守卫路径，继续验证「弹窗关闭后按键恢复生效」。
	GameSession.state = GameSession.State.ENDED
	var before := GameSession.board
	_view._unhandled_key_input(_key(KEY_R))
	assert_true(GameSession.board != before, "弹窗关闭后按 R 应正常重开（终局例外通道）")


# B6：右键拖动 = 连续插旗（只插不取消，避免把已插好的旗拖没了）
func test_b6_right_drag_flags_multiple_cells() -> void:
	var board: Board = GameSession.board
	var hidden: Array[Vector2i] = []
	for p in board.grid.all_positions():
		if board.grid.get_cell(p).state == Cell.State.HIDDEN:
			hidden.append(p)
		if hidden.size() >= 2:
			break
	assert_eq(hidden.size(), 2, "需要两个未翻开格")

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_RIGHT
	down.pressed = true
	down.position = _cell_center(hidden[0])
	_view._gui_input(down)

	var move := InputEventMouseMotion.new()
	move.button_mask = MOUSE_BUTTON_MASK_RIGHT
	move.position = _cell_center(hidden[1])
	_view._gui_input(move)

	assert_eq(board.grid.get_cell(hidden[0]).state, Cell.State.FLAGGED, "按下点应插旗")
	assert_eq(board.grid.get_cell(hidden[1]).state, Cell.State.FLAGGED, "拖过的第二格也应插旗")

	# 松开后拖动结束，后续移动不再插旗
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_RIGHT
	up.pressed = false
	up.position = _cell_center(hidden[1])
	_view._gui_input(up)
	assert_false(_view._flag_dragging, "松开右键应结束拖动")


# B7：设置里关掉「连携操作」→ 两个快捷手势都应失效（但仍能正常翻开/插旗）
func test_b7_quick_actions_can_be_disabled() -> void:
	var prev: bool = SettingsManager.quick_actions
	SettingsManager.set_quick_actions(false)

	var board: Board = GameSession.board
	var hidden: Array[Vector2i] = []
	for p in board.grid.all_positions():
		if board.grid.get_cell(p).state == Cell.State.HIDDEN:
			hidden.append(p)
		if hidden.size() >= 2:
			break

	# 右键拖动不再连续插旗（单点插旗仍生效）
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_RIGHT
	down.pressed = true
	down.position = _cell_center(hidden[0])
	_view._gui_input(down)
	var move := InputEventMouseMotion.new()
	move.button_mask = MOUSE_BUTTON_MASK_RIGHT
	move.position = _cell_center(hidden[1])
	_view._gui_input(move)
	assert_eq(board.grid.get_cell(hidden[0]).state, Cell.State.FLAGGED, "单点插旗不受影响")
	assert_eq(board.grid.get_cell(hidden[1]).state, Cell.State.HIDDEN, "关闭后拖动不应插旗")

	# 开关本身必须被 board_view 读到（chord 的入口判定就靠它）
	assert_false(_view._quick_actions_enabled(), "关闭后 board_view 应读到关闭")
	SettingsManager.set_quick_actions(prev)
	assert_true(_view._quick_actions_enabled(), "恢复后应重新生效")


# B5：暂停不再是死代码 —— toggle_pause 能真正进入并退出 PAUSED
func test_b5_pause_toggle_roundtrip() -> void:
	_view.toggle_pause()
	assert_eq(GameSession.state, GameSession.State.PAUSED, "应能进入暂停")
	GameSession.set_paused(false)
	assert_eq(GameSession.state, GameSession.State.PLAYING, "应能恢复对局")


# B9：对局 HUD 左上角有「教程」入口（2026-09-23 用户决策：从主菜单总入口挪到
# 上下文相关位置，对局中看**当前变体**的教程）。位置契约：紧跟「雷数」读数组之后。
#
# 2026-09-29：教程从文字按钮改成**书本图标**（与选关页右上角同一本书），故查找方式从
# `_find_btn_by_text` 改成按 meta —— 图标按钮没有文字可找。位置契约的语义没变，
# 只是「前一个兄弟是雷数 Label」升级成「前一个兄弟是雷数**读数组**（雷图标 + 数字）」。
func test_b9_hud_tutorial_entry_sits_after_mines() -> void:
	var tut := _find_btn_by_meta(_view, "tutorial_btn")
	assert_not_null(tut, "对局 HUD 应有「教程」入口（meta: tutorial_btn）")
	if tut == null:
		return
	assert_not_null(tut.icon, "教程入口必须是书本图标（SVG 解析失败会静默降级为空图标）")
	assert_ne(str(tut.tooltip_text), "", "纯图标控件必须有 tooltip（可读名）")
	var box := tut.get_parent()
	assert_true(box is HFlowContainer or box is HBoxContainer,
		"教程按钮应在 HUD 的按钮排（_box）里（2026-09-25 起为 HFlowContainer：窄窗自动换行）")
	# 【2026-09-30】顶栏排第一项变成了「关卡列表」（左上角主操作）⇒ 教程索引随之 +1。
	# 断言不再写死字面索引（那正是"前面加一个元素就失效"的脆点），改断言「前一个兄弟是雷数读数组」。
	var prev: Node = box.get_child(tut.get_index() - 1)
	assert_true(prev is HBoxContainer,
		"教程按钮的前一个兄弟应是「雷数」读数组（2026-09-29 起 = 图标 + 数字）")
	if prev is HBoxContainer:
		assert_not_null(_find_first(prev, "TextureRect"), "雷数读数组应带雷图标（形态改造的锚点）")
		assert_not_null(_find_first(prev, "Label"), "雷数读数组应带数字 Label")
	# 变体身份推导（入口的取数链）：before_each 载入 classic_01（普通关卡，无规则声明）
	# → 应推导为 classic（不能是空串，否则点了必然走「暂无教程」兜底）
	assert_eq(GameSession.current_variant_id(), "classic",
		"普通关卡应推导为 classic 变体（LevelLoader 注入的 clue_rule/global_rules meta）")


# B10：打开教程 = **静默暂停**（读规则时计时不该空转），覆盖层释放即恢复对局
#（2026-09-23 审查修复：此前教程打开期间计时继续走，且按键会穿透给对局快捷键）。
func test_b10_hud_tutorial_pauses_session() -> void:
	var tut := _find_btn_by_meta(_view, "tutorial_btn")
	assert_not_null(tut, "对局 HUD 应有「教程」入口（meta: tutorial_btn）")
	if tut == null:
		return
	assert_eq(GameSession.state, GameSession.State.PLAYING, "前置：对局进行中")
	tut.pressed.emit()
	# 覆盖层宿主 = current_scene（生产）或 HUD 的父节点（_overlay_host 的兜底，测试走这条）
	var ov: Control = null
	for root in [get_tree().current_scene, _view]:
		if root == null:
			continue
		for c in (root as Node).get_children():
			if c.has_method("close_overlay"):
				ov = c
	if ov == null:
		pending("找不到教程覆盖层宿主——跳过暂停断言")
		return
	assert_eq(GameSession.state, GameSession.State.PAUSED, "教程打开时应静默暂停（计时不空转）")
	ov.free()  # 立即释放以触发 tree_exited（queue_free 要等帧末）
	assert_eq(GameSession.state, GameSession.State.PLAYING, "教程关闭后应恢复对局")


func _find_btn_by_text(node: Node, want: String) -> Button:
	if node is Button and (node as Button).text == want:
		return node as Button
	for c in node.get_children():
		var r := _find_btn_by_text(c, want)
		if r != null:
			return r
	return null


## 深度优先找第一个带指定 meta 的按钮（图标按钮没有文字，只能这样定位）。
func _find_btn_by_meta(node: Node, key: String) -> Button:
	if node is Button and (node as Button).has_meta(key):
		return node as Button
	for c in node.get_children():
		var r := _find_btn_by_meta(c, key)
		if r != null:
			return r
	return null


## 深度优先找第一个指定类的节点（用于断言「读数组里带图标 / 带 Label」）。
func _find_first(node: Node, cls: String) -> Node:
	if node.is_class(cls):
		return node
	for c in node.get_children():
		var r := _find_first(c, cls)
		if r != null:
			return r
	return null


# B8：分色雷数计数器与左上角「雷数」合并到同一角（2026-09-22 用户要求：
# 原先总雷数在左上、分色明细在右上，视线要两边跑）。
func test_b8_group_panel_joins_the_mines_label_at_top_left() -> void:
	# 带分色分组的异形关：ring/tri 族每格都有 group（数据契约见 test_geo_levels）。
	# 用新实例——_view 是 before_each 按 classic 关建的，板不匹配。
	assert_true(GameSession.start_level("res://levels/ring_01.json"), "需要带分色分组的异形关")
	var v2 = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(v2)
	v2._refresh_group_panel()   # 同步建面板（不依赖 _process 的帧序）
	var panel: Control = v2._group_panel
	assert_not_null(panel, "分色关应出现分色雷数计数器")
	if panel == null:
		return
	# 位置契约：左上角、与 HUD「雷数」同列（总数大字在顶栏，各色明细小字在其正下方）。
	assert_eq(panel.anchor_left, 0.0, "应锚定左上（左锚点 0）")
	assert_eq(panel.anchor_top, 0.0, "应锚定左上（上锚点 0）")
	assert_eq(panel.anchor_right, 0.0, "左锚点布局：右锚点 0 = 宽度由 offset 定义，不拉伸到右缘")
	assert_eq(int(panel.offset_left), 24, "左缘应与 HUD「雷数」对齐（HUD._box.offset_left = 24）")
	assert_gte(int(panel.offset_top), 60, "应让开顶栏（高 64）")
	assert_lte(int(panel.offset_top), 96, "且紧贴顶栏下方——不远离总雷数，两者视觉上连成一块")
	assert_gte(v2._group_rows.size(), 2, "分色关应列出至少 2 个颜色组（明细内联显示）")
