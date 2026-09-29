extends GutTest

## 删线索顺序旋钮（prune_order，v4.1 降废品尝试）的护栏测试。
##
## 背景与**负结论**（2026-09-27 实测，详见 core/puzzle_generator.gd 的 prune_order 注释）：
## 窗口模式的"废品"主因是 peak_miss（难度峰值没落进请求档），而峰值由「删完线索后留下的
## 极小集」决定。曾假设「尝试顺序决定落在哪个极小集」→ 实测推翻：
##   s1_o1@7：in_hard 现状 20% vs 三种新顺序 10%/10%/10%；mean_clue 16.2 vs 16.0/16.1/16.1
##   s1_o1@9：in_hard 现状 30% vs 新顺序 30%（无提升），且耗时 9.2s → 12.9s（恶化 40%）
## 故 **prune_order 默认 0（现状）**，其它策略仅作实验存档。
##
## 本测试钉三件事（防这个旋钮将来被误改）：
##   ① 默认 0 逐位等价旧行为（行优先：先 y 后 x）；
##   ② 各策略下同一 seed 两次运行必须**逐位可复现**；
##   ③ **各策略产出的关卡仍满足 R01**（序贯纯逻辑可解）——"判据未变"的直接验证。


## ① 默认策略 = 行优先（与旧 sort_custom 逐位一致）。
## 注意坐标约定：Vector2i 是 (col, row) = (x, y)，**行优先 = y 小者在前**。
func test_default_order_is_row_major() -> void:
	var gen := PuzzleGenerator.new()
	gen.prune_order = 0
	var values := {Vector2i(0, 1): 1, Vector2i(1, 0): 1}
	var active := {Vector2i(0, 1): 1, Vector2i(1, 0): 1}
	# (1,0) 在第 0 行、(0,1) 在第 1 行 → 行优先时 (1,0) 必须排在前面
	assert_true(gen._prune_less(Vector2i(1, 0), Vector2i(0, 1), values, active),
		"prune_order=0 必须是行优先（y 小者在前）")
	assert_false(gen._prune_less(Vector2i(0, 1), Vector2i(1, 0), values, active),
		"prune_order=0 反向比较应为假（同一行内才比 x）")


## ① 补充：rank 只依赖「值 / 邻域」，不依赖坐标——保证同分回落行优先而非随机。
func test_rank_depends_only_on_value_and_neighborhood() -> void:
	var gen := PuzzleGenerator.new()
	var values := {Vector2i(2, 2): 3, Vector2i(3, 3): 3}
	var active := {Vector2i(2, 2): 3, Vector2i(3, 3): 3}
	for strat in [0, 1, 2, 3]:
		gen.prune_order = strat
		assert_eq(gen._prune_rank(Vector2i(2, 2), values, active),
			gen._prune_rank(Vector2i(3, 3), values, active),
			"同值同邻域的格在策略 %d 下 rank 应相同" % strat)


## 值型安全回归（真实 bug，2026-09-27 由全量回归抓出）：
## 多值线索规则（同格双数字，values[p] 是 Array/Vector2i）下，早期实现直接 int() 会抛
## "Nonexistent 'int' constructor"，一次生成刷上百条引擎错误（GUT 记为 Unexpected Errors）。
## 非 int 值必须**中性**处理，不得强转。
func test_rank_handles_non_int_clue_values() -> void:
	var gen := PuzzleGenerator.new()
	var values := {Vector2i(1, 1): [1, 2], Vector2i(2, 2): Vector2i(3, 4), Vector2i(3, 3): 5}
	var active := {Vector2i(1, 1): [1, 2], Vector2i(2, 2): Vector2i(3, 4), Vector2i(3, 3): 5}
	for strat in [0, 1, 2, 3]:
		gen.prune_order = strat
		for p in values:
			gen._prune_rank(p, values, active)  # 不得抛错（抛错 = 引擎错误 = 测试红）
	gen.prune_order = 1
	assert_eq(gen._prune_rank(Vector2i(1, 1), values, active), 0,
		"非 int 线索值必须中性记 0（不得强转 int）")
	assert_eq(gen._prune_rank(Vector2i(2, 2), values, active), 0,
		"Vector2i 型线索值同样必须中性记 0")
	assert_eq(gen._prune_rank(Vector2i(3, 3), values, active), 5,
		"int 型线索值仍按值排序（策略 1 = 值小先删）")


## 内容指纹：盘面 + 线索数 + 峰值 + 难度（覆盖「盘 + 线索集」两侧，不猜 revealed 的 schema）。
func _fp(level: Dictionary) -> String:
	var ms: Array = []
	for m in level.get("mines", []):
		ms.append("%d,%d" % [int(m["c"]), int(m["r"])])
	ms.sort()
	var dp: Dictionary = level.get("difficulty_profile", {})
	return "%s#%d:%d:%.4f" % ["|".join(ms), int(dp.get("clue_count", -1)),
		int(dp.get("max_complexity", -1)), float(dp.get("difficulty", 0.0))]


## ②③ 各策略：同 seed 两次**逐位可复现**，且产出满足 R01。
func test_strategies_are_deterministic_and_r01_valid() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	for strat in [0, 1, 2, 3]:
		var g1 := PuzzleGenerator.new()
		g1.prune_order = strat
		var g2 := PuzzleGenerator.new()
		g2.prune_order = strat
		var l1: Dictionary = g1.generate_with_rules(
			"classic", ["mx"], Vector2i(6, 6), 14, 7, 0, 50, null, 30_000)
		var l2: Dictionary = g2.generate_with_rules(
			"classic", ["mx"], Vector2i(6, 6), 14, 7, 0, 50, null, 30_000)
		assert_eq(l1.is_empty(), l2.is_empty(),
			"策略 %d 同 seed 两次应同结果（都空或都出关）" % strat)
		if l1.is_empty():
			continue
		assert_eq(_fp(l1), _fp(l2), "策略 %d 同 seed 两次必须逐位可复现" % strat)
		# ③ R01 复核：与 tools/batch_all_variants.gd 的生成后复核同口径
		assert_true(bool(ProofLog.build(l1).get("solved", false)),
			"策略 %d 产出的关卡必须序贯纯逻辑可解（R01）" % strat)
