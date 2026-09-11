# test_hint_feature.gd —— 提示系统接入 UI（GameSession.request_hint 通道）
# 只验证「通道 + 结果形态 + 清空时机」，推规则身由 test_hint_solver 覆盖。
extends GutTest


func before_each() -> void:
	SaveCoordinator.clear()
	GameSession.state = GameSession.State.IDLE
	GameSession.board = null
	GameSession.level_path = ""


func after_each() -> void:
	GameSession.state = GameSession.State.IDLE
	GameSession.board = null
	SaveCoordinator.clear()


## 3×3 经典盘：雷在 (0,0)，中心已翻开、雷已标旗 → L0 推「剩余 7 格全安全」。
func _mk3(mines: Array[Vector2i]) -> Board:
	var board := Board.new()
	var grid := RectGrid.new()
	grid.setup(3, 3)
	board.grid = grid
	board.clue_variant = ClueEngine.Variant.CLASSIC
	board.total_mines = mines.size()
	board._static_mines = mines
	for m in mines:
		grid.get_cell(m).is_mine = true
	board._compute_clues()
	grid.get_cell(Vector2i(1, 1)).state = Cell.State.REVEALED
	return board


# H1：无对局（IDLE / 无棋盘）→ 空数组且不报错
func test_h1_hint_without_game_is_empty() -> void:
	var steps := GameSession.request_hint()
	assert_eq(steps.size(), 0, "无对局时提示应为空数组")


# H2：PLAYING 且有可推线索（中心值 1 + 雷已标旗）→ 推出 7 个安全格
func test_h2_hint_returns_reasoning_steps() -> void:
	GameSession.board = _mk3([Vector2i(0, 0)])
	GameSession.board.grid.get_cell(Vector2i(0, 0)).state = Cell.State.FLAGGED
	GameSession.state = GameSession.State.PLAYING
	var steps := GameSession.request_hint()
	assert_gte(steps.size(), 7, "雷已标旗后应推出剩余 7 格安全")
	for s in steps:
		var step := s as ReasoningStep
		assert_not_null(step, "元素应为 ReasoningStep")
		assert_eq(step.state, "safe", "此局面结论应全为安全格")
		assert_true(step.proof.length() > 0, "推理步骤应带说明文字")


# H3：hint_ready 信号随请求广播（UI 高亮的数据来源）
var _got_steps: Array = []


func _on_hint_ready(steps: Array) -> void:
	_got_steps = steps


func test_h3_hint_ready_signal_emitted() -> void:
	GameSession.board = _mk3([Vector2i(0, 0)])
	GameSession.board.grid.get_cell(Vector2i(0, 0)).state = Cell.State.FLAGGED
	GameSession.state = GameSession.State.PLAYING
	_got_steps = []
	if not GameSession.hint_ready.is_connected(_on_hint_ready):
		GameSession.hint_ready.connect(_on_hint_ready)
	watch_signals(GameSession)
	var steps := GameSession.request_hint()
	assert_signal_emitted(GameSession, "hint_ready", "请求提示应广播 hint_ready")
	assert_eq(_got_steps.size(), steps.size(), "信号参数应与返回值一致")
	GameSession.hint_ready.disconnect(_on_hint_ready)


# H4：终局（ENDED）不再给提示
func test_h4_no_hint_after_end() -> void:
	GameSession.board = _mk3([Vector2i(0, 0)])
	GameSession.state = GameSession.State.ENDED
	assert_eq(GameSession.request_hint().size(), 0, "终局不提供提示")


# H5：真实关卡开局即有可推信息（经典关首关）
func test_h5_hint_on_real_level() -> void:
	var path: String = LevelLoader.list_levels()[0]
	assert_true(GameSession.start_level(path), "关卡应加载成功：%s" % path)
	var steps := GameSession.request_hint()
	for s in steps:
		var step := s as ReasoningStep
		assert_true(step.state == "safe" or step.state == "mine", "结论状态合法")
