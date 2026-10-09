# test_hint_limit.gd —— 提示结论上限与"不消耗"口径（2026-09-28 用户决策）
#
# 背景：旧口径按档位分档（噩梦 3 / 困难 5 / **普通与无画像不限**）——普通档点一次提示
# 会给出全部可确定格（实测几十格 + 一墙推理文字）。用户要求「仅提示一到两个格子的信息
# （是雷、数字还是安全），避免一次性给出过多内容」，并确认「充能改为不消耗」。
#
# 这里钉住两条：①每次结论 ≤2（截断口径 + 顺序稳定）；②对局内端到端也 ≤2。
extends GutTest


func _mk_step(pos: Vector2i, state: String) -> ReasoningStep:
	var s := ReasoningStep.new()
	s.pos = pos
	s.state = state
	s.proof = "测试用"
	return s


func _steps_n(n: int) -> Array[ReasoningStep]:
	var out: Array[ReasoningStep] = []
	for i in n:
		out.append(_mk_step(Vector2i(i, 0), "safe" if i % 2 == 0 else "mine"))
	return out


# ① 上限：多于 2 条时截到上限（取前 2 条）
func test_limit_caps_conclusions_to_two() -> void:
	var hc := HintCoordinator.new()
	var got := hc._limit_hint_budget(_steps_n(9))
	assert_eq(got.size(), HintCoordinator.HINT_MAX_CONCLUSIONS, "9 条结论应被截到上限")
	assert_eq(got.size(), 2, "上限应为 2 格（用户口径：一到两个）")


# ② 不超过上限时原样返回（不丢不复制）
func test_limit_keeps_small_batches_intact() -> void:
	var hc := HintCoordinator.new()
	assert_eq(hc._limit_hint_budget(_steps_n(1)).size(), 1, "1 条应原样返回")
	assert_eq(hc._limit_hint_budget(_steps_n(2)).size(), 2, "2 条应原样返回")
	assert_eq(hc._limit_hint_budget([]).size(), 0, "空数组应原样返回")


# ③ 截断保留**顺序**（前 N 条）：同一局面反复点得到同一批结论，不会飘
func test_limit_keeps_leading_order() -> void:
	var hc := HintCoordinator.new()
	var all := _steps_n(5)
	var got := hc._limit_hint_budget(all)
	assert_eq(got.size(), 2, "前置：应截到 2 条")
	for i in got.size():
		assert_eq(got[i], all[i], "第 %d 条应是原序列的前 N 条（顺序稳定）" % i)


# ④ 端到端：真实对局里 request_hint 的返回也不超过上限
func test_request_hint_respects_cap() -> void:
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	var steps := GameSession.request_hint()
	assert_lte(steps.size(), HintCoordinator.HINT_MAX_CONCLUSIONS,
		"对局内一次提示的结论数不得超过上限（实得 %d）" % steps.size())
	# 不消耗：连点第二次仍能正常返回（充能机制退役前，第二次会因清零而「充能中」）
	var again := GameSession.request_hint()
	assert_lte(again.size(), HintCoordinator.HINT_MAX_CONCLUSIONS,
		"连点第二次同样不得超过上限（实得 %d）" % again.size())


# ⑤ 区域档：只返回一条“可疑区域”提示，不泄露具体雷/安全结论。
func test_region_tier_does_not_reveal_conclusions() -> void:
	var board := Board.new()
	var grid := RectGrid.new()
	grid.setup(3, 3)
	board.grid = grid
	board.clue_variant = ClueEngine.Variant.CLASSIC
	board.total_mines = 1
	board._static_mines = [Vector2i(0, 0)]
	grid.get_cell(Vector2i(0, 0)).is_mine = true
	board._compute_clues()
	grid.get_cell(Vector2i(1, 1)).state = Cell.State.REVEALED
	grid.get_cell(Vector2i(0, 0)).state = Cell.State.FLAGGED
	var got := HintCoordinator.new().compute_hint(board, HintCoordinator.TIER_REGION)
	assert_eq(got.size(), 1, "区域档应只给一条区域提示")
	assert_eq(got[0].method, "region", "区域档必须带 region 标记")
	assert_eq(got[0].state, "region", "区域档不能返回 safe/mine 结论")
	assert_gt(got[0].sources.size(), 0, "区域档应圈出至少一个待观察格")


# ⑥ 整链档：不截断求解器结果（与“给一步”的 ≤2 上限形成对照）。
func test_chain_tier_returns_full_solver_chain() -> void:
	var board := Board.new()
	var grid := RectGrid.new()
	grid.setup(3, 3)
	board.grid = grid
	board.clue_variant = ClueEngine.Variant.CLASSIC
	board.total_mines = 1
	board._static_mines = [Vector2i(0, 0)]
	grid.get_cell(Vector2i(0, 0)).is_mine = true
	board._compute_clues()
	grid.get_cell(Vector2i(1, 1)).state = Cell.State.REVEALED
	grid.get_cell(Vector2i(0, 0)).state = Cell.State.FLAGGED
	var all := HintSolver.new().hint(board)
	var got := HintCoordinator.new().compute_hint(board, HintCoordinator.TIER_CHAIN)
	assert_gte(all.size(), 7, "前置：该 3×3 局面应能推出全部 7 个安全格")
	assert_eq(got.size(), all.size(), "整链档不得截断求解器结果")
	for s in got:
		assert_eq(s.tier, "chain", "整链档每一步都应带 chain 标记")


# ⑦ 星级按本局最差一次求助记：区域 < 一步 < 整链。
func test_star_rating_tracks_worst_hint_tier() -> void:
	GameSession.hint_tier_used = -1
	assert_eq(GameSession.stars_for_session(), 3, "未求助应为 3★")
	GameSession.hint_tier_used = GameSession.HINT_TIER_REGION
	assert_eq(GameSession.stars_for_session(), 2, "只看区域应为 2★")
	GameSession.hint_tier_used = GameSession.HINT_TIER_STEP
	assert_eq(GameSession.stars_for_session(), 1, "给过一步应为 1★")
	GameSession.hint_tier_used = GameSession.HINT_TIER_CHAIN
	assert_eq(GameSession.stars_for_session(), 0, "给过整链应为 0★")
	GameSession.hint_tier_used = -1
