extends GutTest

## 多 G 组合布雷修复验证（v2.9.3）
##
## 旧 bug：_place_mines_rules 只取第一个非空 G 的 place_mines 就 return，导致：
##   ① 状态性 G（dt 骨牌划分）不生成 → build_global_constraints 用空/残留划分，约束静默丢失；
##   ② 布雷偏向第一个 G，其余 G 靠验证重试 → 接受率极低（mx+rl 实测 1.7s 都出不来）。
##
## 修复：多 G 组合用 RuleCpSat.find_solution（CP-SAT 直接求满足全部 G + 总雷数的布局），
## 且含 dt 时先调 dt.place_mines 生成骨牌划分。


func _mine_set(level: Dictionary) -> Dictionary:
	var s := {}
	for m in level["mines"]:
		s[Vector2i(int(m["c"]), int(m["r"]))] = true
	return s


func _row_mines(mines: Dictionary, cols: int, row: int) -> int:
	var n := 0
	for c in cols:
		if mines.has(Vector2i(c, row)):
			n += 1
	return n


## mx+rl（两个非状态性 G）应能生成且同时满足两个约束。
func test_mx_rl_pair_placement() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
		"classic", ["mx", "rl"], Vector2i(5, 5), 10, 1, 0, 50, null, 30_000)
	assert_false(level.is_empty(), "mx+rl 应能生成（旧 bug 下接受率极低常失败）")
	if level.is_empty():
		return
	var mines := _mine_set(level)
	# mx：左右镜像 mine(c,r) == mine(4-c, r)
	for r in 5:
		for c in 2:
			assert_eq(mines.has(Vector2i(c, r)), mines.has(Vector2i(4 - c, r)),
				"mx 镜像约束 row %d col %d/%d 应一致" % [r, c, 4 - c])
	# rl：相邻行雷数差 = 1
	var prev := _row_mines(mines, 5, 0)
	for r in range(1, 5):
		var cur := _row_mines(mines, 5, r)
		assert_eq(absi(cur - prev), 1, "rl 相邻行雷数差应为 1（row %d→%d）" % [r - 1, r])
		prev = cur


## dt 非首位时，骨牌划分不能丢失（旧 bug 的核心症状）。
func test_dt_second_global_keeps_dominoes() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
		"classic", ["mx", "dt"], Vector2i(5, 5), 10, 1, 0, 50, null, 30_000)
	assert_false(level.is_empty(), "mx+dt（dt 非首位）应能生成")
	if level.is_empty():
		return
	assert_true(level.has("dominoes"), "mx+dt 生成结果必须含 dominoes（旧 bug：dt 非首位时骨牌划分丢失）")
	# dt：每骨牌恰 1 雷
	var mines := _mine_set(level)
	for d in level["dominoes"]:
		var n := 0
		for p in d:
			if mines.has(Vector2i(int(p["c"]), int(p["r"]))):
				n += 1
		assert_eq(n, 1, "每骨牌应恰 1 雷（dt 约束）")
