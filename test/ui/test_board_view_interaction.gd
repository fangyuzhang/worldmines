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
	var layer: DrawingLayer = GameSession.drawing_layer
	assert_not_null(layer, "board_view 应把绘画层交给 GameSession")
	assert_true(layer.screen_to_board.is_valid(), "必须注入屏幕→棋盘换算")
	assert_true(layer.board_to_screen.is_valid(), "必须注入棋盘→屏幕换算")


# B2：无猜模式「猜测被拒」必须有可见反馈（原实现零反馈，看起来像卡死）
func test_b2_guess_rejected_has_feedback() -> void:
	var pos: Vector2i = GameSession.board.grid.all_positions()[0]
	GameSession.guess_rejected.emit(pos)
	assert_eq(_view._reject_pos, pos, "被拒格应记录下来用于绘制闪烁反馈")
	assert_gt(_view._reject_until_ms, 0, "应启动一段有限的闪烁时长")


# B3：有可见弹窗时，键盘不得穿透到棋盘（历史 bug：设置弹窗开着按 R 会重开对局）
func test_b3_open_popup_blocks_keys() -> void:
	var dlg := PopupPanel.new()
	add_child_autofree(dlg)
	dlg.popup_centered()
	assert_true(_view._has_open_popup(), "应能识别到可见弹窗")

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

	# elapsed < UiConfirm.TRIVIAL_SEC 时不弹确认，直接重开
	GameSession.elapsed = 0.0
	var before := GameSession.board
	_view._unhandled_key_input(_key(KEY_R))
	assert_true(GameSession.board != before, "弹窗关闭后按 R 应正常重开")


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


# B5：暂停不再是死代码 —— toggle_pause 能真正进入并退出 PAUSED
func test_b5_pause_toggle_roundtrip() -> void:
	_view.toggle_pause()
	assert_eq(GameSession.state, GameSession.State.PAUSED, "应能进入暂停")
	GameSession.set_paused(false)
	assert_eq(GameSession.state, GameSession.State.PLAYING, "应能恢复对局")
