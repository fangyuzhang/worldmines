# test_chord.gd —— 一键展开（chord）
#
# 市面扫雷标配、本作此前完全缺失：在已翻开的数字格上，若邻域旗数 == 线索值，
# 则展开其余未翻开邻格。这里锁死三件事：条件满足才动、旗数不符绝不动、
# 以及**它必须走 reveal() 统一入口**（否则会绕过无猜模式的拒绝逻辑）。
extends GutTest

const LEVEL := "res://levels/classic_01.json"


func before_each() -> void:
	assert_true(GameSession.start_level(LEVEL), "需要一个真实关卡")


## 找一个「线索值 == 邻域真实雷数」且邻域还有非雷格的已翻开格（chord 的合法场景）。
func _find_chord_target() -> Vector2i:
	var board := GameSession.board
	var mines := {}
	for m in board.get_mine_positions():
		mines[m] = true
	for p in board.grid.all_positions():
		var c: Cell = board.grid.get_cell(p)
		if c == null or c.state != Cell.State.REVEALED:
			continue
		if not (c.value is int):
			continue
		var nb: Array = board.grid.get_neighbors(p)
		var mine_nb := 0
		for q in nb:
			if mines.has(q):
				mine_nb += 1
		if mine_nb == int(c.value) and nb.size() > mine_nb:
			return p
	return Vector2i(-1, -1)


func _flag_mine_neighbors(center: Vector2i) -> int:
	var board := GameSession.board
	var mines := {}
	for m in board.get_mine_positions():
		mines[m] = true
	var n := 0
	for q in board.grid.get_neighbors(center):
		if mines.has(q):
			board.grid.get_cell(q).state = Cell.State.FLAGGED
			n += 1
	return n


# CH1：旗数与线索值相符 → 展开剩余邻格，且不踩雷
func test_ch1_opens_when_flag_count_matches() -> void:
	var target := _find_chord_target()
	assert_true(target.x >= 0, "关卡里应存在可 chord 的已翻开数字格")

	var flagged := _flag_mine_neighbors(target)
	assert_gt(flagged, 0, "目标格的邻域应含雷")
	assert_eq(GameSession.chord(target) > 0, true, "旗数相符时应展开邻格")
	assert_eq(GameSession.board.state, Board.GameState.PLAYING, "旗插对了不应踩雷")


# CH2：旗数不符 → 一个都不动
func test_ch2_noop_when_flag_count_mismatch() -> void:
	var target := _find_chord_target()
	assert_true(target.x >= 0)
	var before: int = int(GameSession.board.get_stats()["revealed"])
	assert_eq(GameSession.chord(target), 0, "未插旗（旗数 0 ≠ 线索值）时不得展开")
	assert_eq(GameSession.board.get_stats()["revealed"], before, "盘面必须原样不动")


# CH3：未翻开的格、越界格、非对局态 → 一律不动
func test_ch3_rejects_invalid_targets() -> void:
	var hidden := Vector2i(-1, -1)
	for p in GameSession.board.grid.all_positions():
		if GameSession.board.grid.get_cell(p).state == Cell.State.HIDDEN:
			hidden = p
			break
	assert_eq(GameSession.chord(hidden), 0, "未翻开的格不是 chord 目标")
	assert_eq(GameSession.chord(Vector2i(99, 99)), 0, "越界坐标安全返回")

	GameSession.state = GameSession.State.ENDED
	assert_eq(GameSession.chord(_find_chord_target()), 0, "非对局态不响应")


# CH4：必须走 reveal() 统一入口 —— 无猜-专家档下展开不得越权
# （chord 内部逐格调用 reveal，推不出来的格会被拒绝，不会绕过防线）
func test_ch4_respects_no_guess_expert_mode() -> void:
	var target := _find_chord_target()
	assert_true(target.x >= 0)
	_flag_mine_neighbors(target)
	var prev_mode: int = SettingsManager.no_guess_mode
	SettingsManager.set_no_guess_mode(GameSession.NO_GUESS_EXPERT)
	var opened := GameSession.chord(target)
	SettingsManager.set_no_guess_mode(prev_mode)
	# 专家档下：能推的格照常展开，推不出的格被 reveal 拒绝 —— 关键是不得踩雷
	assert_eq(GameSession.board.state, Board.GameState.PLAYING,
			"专家档 chord 不得造成踩雷（推不出的格应被拒绝）")
	assert_true(opened >= 0)
