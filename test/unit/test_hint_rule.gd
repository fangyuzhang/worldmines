extends GutTest

## 规则关卡提示（v2.9.3）
##
## 背景：旧 `HintSolver.hint()` 对非 classic 规则关卡**直接返回空**——Def 推理只覆盖
## 内置变体的有限窗口，套用到 knight 等自定义窗口会给出错误结论，故宁可不给。
## 结果是 15 变体里只有 classic 能出提示。
##
## v2.9.3 改为走 `hint_rule()`（RuleOracle 组装 spec → CP-SAT forced-cell），
## 覆盖全部线索规则 + 全局约束，且 spec 自带 total_mines。
##
## 本测试验证两件事：
##   ① 各规则关卡都能给出提示（不再只对 classic 生效）；
##   ② **soundness**：每条提示结论必须与真值一致（提示永不害死玩家的底线）。

const SIZE := Vector2i(5, 5)
const MINES := 4
const SEED_TRIES := 10


## 在若干种子内尝试生成，返回第一个成功的可解关卡（生成失败返回空 dict）。
func _try_generate(clue_id: String, globals: Array) -> Dictionary:
	var gen := PuzzleGenerator.new()
	for s in SEED_TRIES:
		var level: Dictionary = gen.generate_with_rules(clue_id, globals, SIZE, MINES, 1000 + s * 7)
		if not level.is_empty():
			return level
	return {}


func _true_mine_set(level: Dictionary) -> Dictionary:
	var s := {}
	for m in level.get("mines", []):
		s[Vector2i(int(m["c"]), int(m["r"]))] = true
	return s


## soundness：mine 提示必须真是雷；safe 提示必须真不是雷。
func _assert_sound(level: Dictionary, steps: Array, tag: String) -> void:
	var mines := _true_mine_set(level)
	for st in steps:
		var is_mine: bool = mines.has(st.pos)
		if st.state == "mine":
			assert_true(is_mine, "%s：提示为雷的格 (%d,%d) 真值必须是雷" % [tag, st.pos.y, st.pos.x])
		elif st.state == "safe":
			assert_false(is_mine, "%s：提示为安全的格 (%d,%d) 真值不能是雷" % [tag, st.pos.y, st.pos.x])


## 提示目标格必须是玩家尚未确定的格（已翻开/已插旗不该再出现在结论里）。
func _assert_targets_unresolved(board: Board, steps: Array, tag: String) -> void:
	for st in steps:
		var c: Cell = board.grid.get_cell(st.pos)
		assert_true(c != null, "%s：结论格在盘内" % tag)
		if c == null:
			continue
		assert_true(c.state != Cell.State.REVEALED, "%s：已翻开的格不该再作为结论" % tag)
		if st.state == "safe":
			assert_true(c.state != Cell.State.FLAGGED, "%s：已插旗的格不该被判安全" % tag)


## 旧实现在此处 100% 返回空（错误窗口比没提示更糟）→ 现已能推。
func test_hint_knight_rule_level() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate("knight", [])
	assert_false(level.is_empty(), "knight 规则关卡应能生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)
	assert_eq(b.rule_clue_id, "knight", "Board 应识别规则关卡")

	var steps: Array = HintSolver.new().hint(b)
	assert_gt(steps.size(), 0, "knight 规则关卡应能给出提示（旧实现此处恒为 0）")
	_assert_sound(level, steps, "knight")
	_assert_targets_unresolved(b, steps, "knight")


## 全线索规则遍历：每个规则都要能出提示，且结论必须与真值一致。
func test_hint_all_clue_rules_sound() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	# fr 为射线语义、序贯可解性差，单列不在此测（与 test_rule_platform 同口径）
	for rule_id in ["classic", "4n", "sc", "knight", "distsum", "clock", "loopruns", "hv"]:
		var level := _try_generate(rule_id, [])
		assert_false(level.is_empty(), "%s 关卡应能生成" % rule_id)
		if level.is_empty():
			continue
		var b := Board.new()
		b.load_level(level)
		var steps: Array = HintSolver.new().hint(b)
		assert_gt(steps.size(), 0, "%s 规则关卡应能给出提示" % rule_id)
		_assert_sound(level, steps, rule_id)
		_assert_targets_unresolved(b, steps, rule_id)


## 全局约束关卡（镜像 MX）：提示必须同样可用且 sound。
func test_hint_global_rule_level() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate("classic", ["mx"])
	assert_false(level.is_empty(), "classic+mx 关卡应能生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)
	var steps: Array = HintSolver.new().hint(b)
	assert_gt(steps.size(), 0, "含全局约束的规则关卡应能给出提示")
	_assert_sound(level, steps, "classic+mx")


## 提示三档（对标 doc10 §3.2）：禁用档必须完全关闭提示，恢复后又能用。
## 直接改 SettingsManager 字段（不调 setter，避免测试污染用户配置文件）。
func test_hint_mode_disabled_gates_request() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate("classic", [])
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)

	var saved_mode: int = SettingsManager.hint_mode
	var saved_state: int = GameSession.state
	var saved_board: Board = GameSession.board
	GameSession.board = b
	GameSession.state = GameSession.State.PLAYING

	SettingsManager.hint_mode = 0
	var normal_steps: Array = GameSession.request_hint()
	assert_gt(normal_steps.size(), 0, "标准档应能给出提示")

	SettingsManager.hint_mode = 2  # 禁用
	var off_steps: Array = GameSession.request_hint()
	assert_eq(off_steps.size(), 0, "禁用档必须完全关闭提示")

	SettingsManager.hint_mode = 1  # 弱提示：结论仍在，但标记为 weak（UI 不画结论格）
	var weak_steps: Array = GameSession.request_hint()
	assert_gt(weak_steps.size(), 0, "弱提示仍应返回结论（只是 UI 不展示）")
	for st in weak_steps:
		assert_eq(st.method, "weak", "弱提示档的每条结论都应标记 method=weak")

	SettingsManager.hint_mode = saved_mode
	GameSession.state = saved_state
	GameSession.board = saved_board


## 零信任回归：玩家插错旗时，提示不得把含雷格判成安全。
## （「已标数 == 线索值 ⇒ 剩余安全」在错旗下会击穿「100% 必然」承诺）
func test_hint_zero_trust_wrong_flag() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate("classic", [])
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)
	# 找一个「真值不是雷」的未翻开格，故意插错旗
	var wrong := Vector2i(-1, -1)
	var sz: Vector2i = b.grid.size()
	for y in sz.y:
		for x in sz.x:
			var p := Vector2i(x, y)
			var c: Cell = b.grid.get_cell(p)
			if c.state == Cell.State.REVEALED:
				continue
			if c.is_mine:
				continue
			wrong = p
			break
		if wrong.x >= 0:
			break
	if wrong.x < 0:
		pending("未找到可插错旗的格")
		return
	b.grid.get_cell(wrong).state = Cell.State.FLAGGED

	var steps: Array = HintSolver.new().hint(b)
	# 关键：错旗不得导致任何「把真雷判成安全」的结论
	var mines := _true_mine_set(level)
	for st in steps:
		if st.state == "safe":
			assert_false(mines.has(st.pos),
				"错旗下不得把真雷格 (%d,%d) 判为安全" % [st.pos.y, st.pos.x])
