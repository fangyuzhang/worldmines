extends GutTest

## 终极模式（对标 doc10 §2.4，v2.9.3）
##
## 机制：玩家**新翻开的线索格一律显示为星号**（值隐藏），直到玩家点提示且当前
## 确实推不出任何安全格时，星号才变成线索、对局继续。
##
## 实现要点：星号只影响「玩家视角」——`Cell.get_player_constraint()` 对星号格返回
## `{"type":"none"}`，于是提示/推理自动拿不到它的值；引擎真值、胜负、离线验证不受影响。

const SIZE := Vector2i(5, 5)
const MINES := 4

## 本测试直赋 GameSession.board 后会触发 GameSession.reveal/_maybe_auto_ultimate_hint，
## 内部可能走 _maybe_autosave——不关自动存档会把 level_path="" 的档写进真实 user://，
## 下次启动游戏误报「存档已损坏」（v3.2 事故溯源结论）。
var _saved_autosave: bool = true


func before_all() -> void:
	_saved_autosave = SettingsManager.autosave_enabled
	SettingsManager.autosave_enabled = false


func after_all() -> void:
	SettingsManager.autosave_enabled = _saved_autosave
	SaveCoordinator.clear()  # 双保险：清可能残留的测试档


func _try_generate(clue_id: String, globals: Array) -> Dictionary:
	var gen := PuzzleGenerator.new()
	for s in 10:
		var level: Dictionary = gen.generate_with_rules(clue_id, globals, SIZE, MINES, 1000 + s * 7)
		if not level.is_empty():
			return level
	return {}


func _true_mine_set(level: Dictionary) -> Dictionary:
	var s := {}
	for m in level.get("mines", []):
		s[Vector2i(int(m["c"]), int(m["r"]))] = true
	return s


## 星号格在玩家视角必须「无线索」——这是终极模式的难度来源，也是不能泄露真值的关键。
func test_star_hides_clue_from_player_view() -> void:
	var level := _try_generate("classic", [])
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)
	b.hide_new_clues = true
	assert_false(b.has_stars(), "初始线索不打星（否则开局无法推理）")

	# 翻开一个真值安全的隐藏格
	var mines := _true_mine_set(level)
	var target := Vector2i(-1, -1)
	var sz: Vector2i = b.grid.size()
	for y in sz.y:
		for x in sz.x:
			var p := Vector2i(x, y)
			if b.grid.get_cell(p).state == Cell.State.HIDDEN and not mines.has(p):
				target = p
				break
		if target.x >= 0:
			break
	assert_true(target.x >= 0, "应有可翻开的隐藏安全格")
	b.reveal(target)

	assert_true(b.has_stars(), "终极模式下新翻开的线索格应被打星号")
	# 找任一星号格，断言玩家视角拿不到值
	var star_pos := Vector2i(-1, -1)
	for y in sz.y:
		for x in sz.x:
			var p := Vector2i(x, y)
			if b.grid.get_cell(p).starred:
				star_pos = p
				break
		if star_pos.x >= 0:
			break
	assert_true(star_pos.x >= 0, "应存在星号格")
	assert_eq(str(b.get_player_constraint(star_pos).get("type", "")), "none",
		"星号格在玩家视角必须无线索（值隐藏）")

	# 揭开星号 → 恢复为正常线索
	var n := b.reveal_stars()
	assert_gt(n, 0, "reveal_stars 应揭开至少一格")
	assert_false(b.has_stars(), "揭开后不应再有星号格")
	assert_ne(str(b.get_player_constraint(star_pos).get("type", "")), "none",
		"揭开后该格应恢复为正常线索")


## 卡住时点提示 → 星号变线索（对标 doc10 §2.4）。
## 构造：把全部已翻开格都打星，玩家视角就完全无线索 → 必然无可推格。
func test_ultimate_hint_reveals_stars_when_stuck() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate("classic", [])
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)
	for p in b.grid.all_positions():
		var c: Cell = b.grid.get_cell(p)
		if c.state == Cell.State.REVEALED:
			c.starred = true
	assert_true(b.has_stars(), "前置：应存在星号格")

	var saved_mode: int = SettingsManager.no_guess_mode
	var saved_hint: int = SettingsManager.hint_mode
	var saved_state: int = GameSession.state
	var saved_board: Board = GameSession.board
	GameSession.board = b
	GameSession.state = GameSession.State.PLAYING
	SettingsManager.no_guess_mode = 2  # 终极
	SettingsManager.hint_mode = 0      # 标准提示（未禁用）

	var steps: Array = GameSession.request_hint()
	assert_false(b.has_stars(), "推不出安全格时点提示 → 星号应被揭开")
	assert_eq(steps.size(), 0, "揭开星号这一步本身不返回推理结论")

	SettingsManager.no_guess_mode = saved_mode
	SettingsManager.hint_mode = saved_hint
	GameSession.state = saved_state
	GameSession.board = saved_board


## 附加开关 AddOnAutoReveal：卡住时自动揭星，免手动点提示。
func test_auto_reveal_when_stuck() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate("classic", [])
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)
	# 把全部已翻开格打星 + 让本次新翻开的格也打星 → 玩家视角完全无线索 → 必然推不动
	b.hide_new_clues = true
	for p in b.grid.all_positions():
		var c: Cell = b.grid.get_cell(p)
		if c.state == Cell.State.REVEALED:
			c.starred = true

	var saved_mode: int = SettingsManager.no_guess_mode
	var saved_hint: int = SettingsManager.hint_mode
	var saved_auto: bool = SettingsManager.ult_auto_reveal
	var saved_state: int = GameSession.state
	var saved_board: Board = GameSession.board
	GameSession.board = b
	GameSession.state = GameSession.State.PLAYING
	SettingsManager.no_guess_mode = 2
	SettingsManager.hint_mode = 0
	SettingsManager.ult_auto_reveal = true

	# 翻一个真值安全的隐藏格 → 翻完自动判定「推不动」→ 自动揭星
	var mines := _true_mine_set(level)
	var target := Vector2i(-1, -1)
	var sz: Vector2i = b.grid.size()
	for y in sz.y:
		for x in sz.x:
			var p := Vector2i(x, y)
			if b.grid.get_cell(p).state == Cell.State.HIDDEN and not mines.has(p):
				target = p
				break
		if target.x >= 0:
			break
	if target.x < 0:
		pending("未找到可翻开的隐藏安全格")
		return
	# 直接驱动「卡住自动揭星」的判定（不经 reveal，避免一翻即终局时按设计跳过自动揭星）
	GameSession._maybe_auto_ultimate_hint()
	assert_false(b.has_stars(), "开启自动揭星后，卡住时应自动揭开星号")

	SettingsManager.no_guess_mode = saved_mode
	SettingsManager.hint_mode = saved_hint
	SettingsManager.ult_auto_reveal = saved_auto
	GameSession.state = saved_state
	GameSession.board = saved_board


## 反向对照：未开启「卡住自动揭星」时，星号必须原样保留（不许自作主张替玩家揭）。
func test_auto_reveal_off_keeps_stars() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate("classic", [])
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)
	for p in b.grid.all_positions():
		var c: Cell = b.grid.get_cell(p)
		if c.state == Cell.State.REVEALED:
			c.starred = true

	var saved_mode: int = SettingsManager.no_guess_mode
	var saved_auto: bool = SettingsManager.ult_auto_reveal
	var saved_state: int = GameSession.state
	var saved_board: Board = GameSession.board
	GameSession.board = b
	GameSession.state = GameSession.State.PLAYING
	SettingsManager.no_guess_mode = 2
	SettingsManager.ult_auto_reveal = false  # 关闭

	GameSession._maybe_auto_ultimate_hint()
	assert_true(b.has_stars(), "未开启自动揭星时星号必须保留")

	SettingsManager.no_guess_mode = saved_mode
	SettingsManager.ult_auto_reveal = saved_auto
	GameSession.state = saved_state
	GameSession.board = saved_board


## 可断定格数查询：与提示里的 safe 结论数必须一致（不变量）。
## 注意：某阶段「只有必雷结论、没有必安结论」是合法情形，故不假设它一定 > 0。
func test_deducible_safe_count_positive() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate("classic", [])
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)
	var saved_state: int = GameSession.state
	var saved_board: Board = GameSession.board
	GameSession.board = b
	GameSession.state = GameSession.State.PLAYING
	var steps: Array = HintSolver.new().hint(b)
	assert_gt(steps.size(), 0, "序贯可解关卡的初始盘面应有可推出的结论")
	var expect := 0
	for st in steps:
		if (st as ReasoningStep).state == "safe":
			expect += 1
	assert_eq(GameSession.deducible_safe_count(), expect,
		"可断定安全格数应与提示中的 safe 结论数一致")
	GameSession.state = saved_state
	GameSession.board = saved_board


## 终极档不禁止猜测（难度来自星号遮蔽，不是禁止操作）——与专家档语义区分。
func test_ultimate_does_not_block_guessing() -> void:
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
	SettingsManager.no_guess_mode = 2  # 终极

	# 找一个「推不出来」的隐藏格：终极档下必须照常翻开（不拦截）
	var guess_pos := Vector2i(-1, -1)
	var sz: Vector2i = b.grid.size()
	for y in sz.y:
		for x in sz.x:
			var p := Vector2i(x, y)
			if b.grid.get_cell(p).state != Cell.State.HIDDEN:
				continue
			if not GameSession.is_deducible_safe(p):
				guess_pos = p
				break
		if guess_pos.x >= 0:
			break
	if guess_pos.x < 0:
		pending("未找到推不出来的隐藏格")
		return
	GameSession.reveal(guess_pos)
	assert_ne(b.grid.get_cell(guess_pos).state, Cell.State.FLAGGED,
		"终极档不该像专家档那样拦截猜测")

	SettingsManager.no_guess_mode = saved_mode
	GameSession.state = saved_state
	GameSession.board = saved_board
