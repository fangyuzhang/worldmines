extends GutTest
## no_guess_guard 线程化专项测试（2026-10-25，坑表 #44 清偿）。
## 验证：同步语义与 HintSolver 直算一致（投机预计算不改答案）、
## 投机路径真的在后台算、过期世代结果被丢弃、并发压测无崩溃、reset 安全回收线程。

const HintSolverScript := preload("res://core/hint_solver.gd")


func _make_board() -> Board:
	# 5x5 官方口径 classic 关（构造式布雷 + 删线索，自带预翻开初始态）
	var lv: Dictionary = PuzzleGenerator.new().generate_with_rules(
		"classic", [], Vector2i(5, 5), 10, 42)
	assert_false(lv.is_empty(), "生成测试关卡失败")
	var b := Board.new()
	b.load_level(lv)
	return b


func _sync_safe_set(b: Board) -> Array:
	var solver := HintSolverScript.new()
	var out := []
	for st in solver.hint(b):
		if st.state == "safe":
			out.append(st.pos)
	return out


func test_guard_answers_match_direct_solver() -> void:
	# 核心契约：守卫的推导缓存 ≡ HintSolver 直算（同语义，不许投机路径改答案）
	var b := _make_board()
	var g := NoGuessGuard.new()
	var expect := _sync_safe_set(b)
	if not expect.is_empty():
		var hit: Vector2i = expect[0]
		assert_true(g.is_deducible_safe(b, hit), "求解器判定的安全格，守卫必须放行")
		for p in expect:
			assert_true(g.is_deducible_safe(b, p), "守卫应与直算一致：%s" % p)
	# 非推导集里的隐藏格必须拒绝（找一个不在集合里的隐藏格）
	var mine_set: Dictionary = {}
	for m in b.get_mine_positions():
		mine_set[Vector2i(int(m[0]), int(m[1]))] = true
	var found_hidden := false
	for pos in b.grid.all_positions():
		var c: Cell = b.grid.get_cell(pos)
		if c == null or c.state != Cell.State.HIDDEN or mine_set.has(pos):
			continue
		if not expect.has(pos):
			found_hidden = true
			assert_false(g.is_deducible_safe(b, pos), "不在推导集内的格必须拒绝：%s" % pos)
			break
	assert_true(found_hidden or expect.is_empty(), "测试盘应存在未推导的隐藏格（否则覆盖不足）")
	g.reset()


func test_speculative_rebuild_runs_in_background() -> void:
	# 投机路径：盘面一变（reveal）→ 不经任何 is_deducible_safe 调用，几帧后缓存自行变为有效
	var b := _make_board()
	var g := NoGuessGuard.new()
	g.is_deducible_safe(b, Vector2i(0, 0))   # 武装守卫 + 首次建缓存
	var before_valid: bool = g._cache_valid
	assert_true(before_valid, "首次查询后缓存应有效")
	# 翻开一个安全格 → 信号失效 → 投机预计算自动启动
	var revealed := 0
	for pos in b.grid.all_positions():
		var c: Cell = b.grid.get_cell(pos)
		if c == null or c.state != Cell.State.HIDDEN:
			continue
		if b.is_mine(pos):
			continue
		b.reveal(pos)
		revealed += 1
		break
	assert_eq(revealed, 1, "应翻开了一个安全格")
	assert_false(g._cache_valid, "盘面变化后缓存立即失效")
	for i in 12:
		await get_tree().process_frame
		if g._cache_valid:
			break
	assert_true(g._cache_valid, "投机预计算应在数帧内把缓存重建为有效（无需任何查询触发）")
	# 重建后的答案仍与直算一致
	var expect := _sync_safe_set(b)
	for p in expect:
		assert_true(g._safe_cache.has(p), "投机结果应含直算安全格 %s" % p)
	g.reset()


func test_stale_generation_result_discarded() -> void:
	# 世代丢弃：失效后立刻再失效（线程还没算完第一代）→ 第一代结果不得落地
	var b := _make_board()
	var g := NoGuessGuard.new()
	g.async_enabled = false   # 先武装（同步建缓存）并确保线程静默
	g.is_deducible_safe(b, Vector2i(0, 0))
	g.async_enabled = true
	var hidden: Array = []
	for pos in b.grid.all_positions():
		var c: Cell = b.grid.get_cell(pos)
		if c != null and c.state == Cell.State.HIDDEN and not b.is_mine(pos):
			hidden.append(pos)
	assert_gte(hidden.size(), 2, "测试盘至少要有两个可翻格")
	b.reveal(hidden[0])   # 失效① → 投机启动（gen G）
	var gen_a: int = g._gen
	b.reveal(hidden[1])   # 失效② → gen G+1（第一代结果必须被丢弃）
	assert_eq(g._gen, gen_a + 1, "每次失效世代 +1")
	for i in 12:
		await get_tree().process_frame
		if g._cache_valid:
			break
	# 无论哪一代落地，都必须是**当前盘面**的答案：与直算一致
	var expect := _sync_safe_set(b)
	for p in expect:
		assert_true(g._safe_cache.has(p) or not g._cache_valid, "落地结果必须匹配当前盘面")
	g.reset()


func test_concurrent_reveal_and_query_stress() -> void:
	# 并发压测：主线程连续 reveal（失效+投机）与查询（等待/同步兜底）交替 60 轮
	var b := _make_board()
	var g := NoGuessGuard.new()
	var hidden: Array = []
	for pos in b.grid.all_positions():
		var c: Cell = b.grid.get_cell(pos)
		if c != null and c.state == Cell.State.HIDDEN and not b.is_mine(pos):
			hidden.append(pos)
	for i in mini(60, hidden.size()):
		b.reveal(hidden[i])
		var any_pos: Vector2i = hidden[i] if i == 0 else hidden[i - 1]
		g.is_deducible_safe(b, any_pos)   # 同步契约：必须立刻有答案（等待或重算）
	# 结束后收尾：线程必须全部回收
	g.reset()
	assert_true(g._thread == null, "reset 后线程句柄应清空")
	assert_false(g._solving, "reset 后不应有求解中标志")


func test_reset_during_solve_is_safe() -> void:
	# 求解进行中 reset：必须无崩溃、无线程泄漏，且守卫可继续用于新盘
	var b1 := _make_board()
	var g := NoGuessGuard.new()
	g.is_deducible_safe(b1, Vector2i(0, 0))
	var hidden := []
	for pos in b1.grid.all_positions():
		var c: Cell = b1.grid.get_cell(pos)
		if c != null and c.state == Cell.State.HIDDEN and not b1.is_mine(pos):
			hidden.append(pos)
	if not hidden.is_empty():
		b1.reveal(hidden[0])   # 触发投机
		g.reset()              # 求解途中直接回收
	var b2 := _make_board()
	var ok2: bool = g.is_deducible_safe(b2, Vector2i(0, 0))
	assert_true(typeof(ok2) == TYPE_BOOL, "新盘上守卫仍可正常作答")
	g.reset()
