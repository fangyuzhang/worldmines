extends GutTest

## 无猜模式（v2.9.3，对标 doc10 §2；红线兼容实现）
##
## 对标游戏的「专家模式」靠「猜错就重排剩余雷」实现，即移动雷位——会破坏
## 本作 R01 序贯可解验证与写死的关卡数据。本实现改为**拒绝**翻开推不出来的格：
## 数学保证相同（玩家无法靠猜蒙混），且不碰任何关卡数据。
##
## 本测试验证：① 推不出来的格被拒绝且盘面不变；② 能推出来的安全格仍可正常翻开。

const SIZE := Vector2i(5, 5)
const MINES := 4


func _try_generate(clue_id: String, globals: Array) -> Dictionary:
	var gen := PuzzleGenerator.new()
	for s in 10:
		var level: Dictionary = gen.generate_with_rules(clue_id, globals, SIZE, MINES, 1000 + s * 7)
		if not level.is_empty():
			return level
	return {}


func test_no_guess_expert_rejects_and_allows() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate("classic", [])
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return

	var b := Board.new()
	b.load_level(level)

	var saved_mode: int = SettingsManager.no_guess_mode
	var saved_state: int = GameSession.state
	var saved_board: Board = GameSession.board
	GameSession.board = b
	GameSession.state = GameSession.State.PLAYING
	SettingsManager.no_guess_mode = 1  # 专家：禁止猜测

	# 扫一遍：分别找一个「推不出来」和「能推出安全」的隐藏格
	var guess_pos := Vector2i(-1, -1)
	var safe_pos := Vector2i(-1, -1)
	var sz: Vector2i = b.grid.size()
	for y in sz.y:
		for x in sz.x:
			var p := Vector2i(x, y)
			if b.grid.get_cell(p).state != Cell.State.HIDDEN:
				continue
			if GameSession.is_deducible_safe(p):
				if safe_pos.x < 0:
					safe_pos = p
			elif guess_pos.x < 0:
				guess_pos = p
	assert_true(guess_pos.x >= 0, "应存在一个当前推不出来的隐藏格")
	assert_true(safe_pos.x >= 0, "应存在一个当前可推出安全的格（关卡序贯可解）")

	# ① 猜测必须被拒绝，且盘面不变
	var rejected_signal := []
	GameSession.guess_rejected.connect(func(p: Vector2i): rejected_signal.append(p))
	GameSession.reveal(guess_pos)
	assert_eq(b.grid.get_cell(guess_pos).state, Cell.State.HIDDEN,
		"无猜模式下推不出来的格不得被翻开")
	assert_eq(rejected_signal.size(), 1, "应广播一次 guess_rejected")
	assert_eq(GameSession.rejected_guess_count(), 1, "拒绝计数应为 1")

	# ② 可推出的安全格仍能正常翻开
	GameSession.reveal(safe_pos)
	assert_eq(b.grid.get_cell(safe_pos).state, Cell.State.REVEALED,
		"可推出的安全格应能正常翻开")

	SettingsManager.no_guess_mode = saved_mode
	GameSession.state = saved_state
	GameSession.board = saved_board


## 关闭档（默认）不得拦截任何翻开——保证既有玩法零回归。
func test_no_guess_off_allows_any_reveal() -> void:
	var level := _try_generate("classic", [])
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)

	var saved_mode: int = SettingsManager.no_guess_mode
	var saved_state: int = GameSession.state
	var saved_board: Board = GameSession.board
	GameSession.board = b
	GameSession.state = GameSession.State.PLAYING
	SettingsManager.no_guess_mode = 0  # 关闭

	# 挑任意一个隐藏格（不做可推性判断）→ 必须照常翻开
	var pos := Vector2i(-1, -1)
	var sz: Vector2i = b.grid.size()
	for y in sz.y:
		for x in sz.x:
			var p := Vector2i(x, y)
			if b.grid.get_cell(p).state == Cell.State.HIDDEN:
				pos = p
				break
		if pos.x >= 0:
			break
	assert_true(pos.x >= 0, "应存在隐藏格")
	GameSession.reveal(pos)
	assert_eq(b.grid.get_cell(pos).state, Cell.State.REVEALED, "关闭档应照常翻开")

	SettingsManager.no_guess_mode = saved_mode
	GameSession.state = saved_state
	GameSession.board = saved_board
