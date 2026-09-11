# test_difficulty_crosscheck.gd —— 交叉验证：难度量化新代码的正确性（双后端对拍 + 确定性）
extends GutTest


## IsForcedCell（新 C# 单格探测）与 FindForcedCells（全格探测）对拍：
## 用生成器产出的「有解」线索集，对每个自由格，两者「是否被强制」应一致。
func test_is_forced_matches_find_forced() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var lv := PuzzleGenerator.new().generate_with_rules("classic", [], Vector2i(5, 5), 3, 1)
	if lv.is_empty():
		pending("生成失败（跳过）")
		return
	var board := Board.new()
	board.load_level(lv)
	var active := {}
	for rc in lv["revealed"]:
		var p := Vector2i(int(rc["c"]), int(rc["r"]))
		active[p] = board.grid.get_cell(p).value
	var total := int(lv["total_mines"])
	var classic: Object = RuleRegistry.default().resolve(&"classic")
	var oracle := RuleOracle.new(classic, [], Vector2i(5, 5), total)
	var spec := oracle.build_spec(active)
	assert_true(RuleCpSat.is_feasible(spec), "spec 应有解")
	var forced := RuleCpSat.find_forced_cells(spec)
	var forced_mines := {}
	for m in forced.get("mine", []):
		forced_mines[Vector2i(int(m[1]), int(m[0]))] = true
	var forced_safe := {}
	for s in forced.get("safe", []):
		forced_safe[Vector2i(int(s[1]), int(s[0]))] = true
	# 对拍：自由格（非已知线索格）的「强制」判断应一致
	var checked := 0
	for r in 5:
		for c in 5:
			var p := Vector2i(c, r)
			if active.has(p):
				continue
			var in_forced := forced_mines.has(p) or forced_safe.has(p)
			var single := RuleCpSat.is_forced_cell(spec, r, c)
			assert_eq(single, in_forced, "IsForcedCell 应与 FindForcedCells 一致 @%s" % str(p))
			checked += 1
	assert_gt(checked, 0, "应有自由格可对拍")


## 难度画像确定性：同 seed 两次生成，difficulty_profile 应完全一致（含 max_complexity/histogram）。
func test_difficulty_deterministic() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var lv1 := PuzzleGenerator.new().generate_with_rules("classic", [], Vector2i(5, 5), 10, 7)
	var lv2 := PuzzleGenerator.new().generate_with_rules("classic", [], Vector2i(5, 5), 10, 7)
	assert_false(lv1.is_empty(), "lv1 应生成")
	assert_false(lv2.is_empty(), "lv2 应生成")
	if lv1.is_empty() or lv2.is_empty():
		return
	assert_eq(str(lv1["difficulty_profile"]), str(lv2["difficulty_profile"]),
		"同 seed 难度画像应确定一致")


## 难度画像自洽：max_complexity ≤ max_active（必要线索数基于演绎中途的线索集，
## 可超过初始 clue_count——演绎中翻开新格使线索变多）。
func test_max_complexity_bounded() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	for seed in range(1, 5):
		var lv := PuzzleGenerator.new().generate_with_rules("classic", [], Vector2i(6, 6), 14, seed)
		if lv.is_empty():
			continue
		var dp: Dictionary = lv["difficulty_profile"]
		var mc := int(dp["max_complexity"])
		var ma := int(dp["max_active"])
		assert_true(mc <= ma, "max_complexity(%d) 应 ≤ max_active(%d)（seed %d）" % [mc, ma, seed])
		assert_true(mc > 0, "max_complexity 应为正（seed %d）" % seed)


## unsat_core 必要线索数（minimal_clue_count_unsat）直接正确性：
## 对每个被强制的格，必要线索数应在 [1, 线索数]；不被强制的格返回 -1。
## 这是 P0 难度量化的底层（max_complexity 数据源），此前只有间接覆盖。
func test_unsat_core_clue_count_bounds() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var lv := PuzzleGenerator.new().generate_with_rules("classic", [], Vector2i(5, 5), 3, 1)
	if lv.is_empty():
		pending("生成失败（跳过）")
		return
	var board := Board.new()
	board.load_level(lv)
	var active := {}
	for rc in lv["revealed"]:
		var p := Vector2i(int(rc["c"]), int(rc["r"]))
		active[p] = board.grid.get_cell(p).value
	var total := int(lv["total_mines"])
	var classic: Object = RuleRegistry.default().resolve(&"classic")
	var oracle := RuleOracle.new(classic, [], Vector2i(5, 5), total)
	var spec := oracle.build_spec(active)
	var clue_count := active.size()
	assert_true(RuleCpSat.is_feasible(spec), "spec 应有解")

	var forced := RuleCpSat.find_forced_cells(spec)
	var forced_set := {}
	for m in forced.get("mine", []):
		forced_set[Vector2i(int(m[1]), int(m[0]))] = true
	for s in forced.get("safe", []):
		forced_set[Vector2i(int(s[1]), int(s[0]))] = true

	var checked_forced := 0
	var checked_free := 0
	for r in 5:
		for c in 5:
			var p := Vector2i(c, r)
			if active.has(p):
				continue
			var k := RuleCpSat.minimal_clue_count_unsat(spec, r, c)
			if forced_set.has(p):
				# 被强制：必要线索数应在 [1, clue_count]
				assert_true(k >= 1 and k <= clue_count,
					"强制格 %s 必要线索数 %d 应在 [1, %d]" % [str(p), k, clue_count])
				checked_forced += 1
			else:
				# 不被强制：返回 -1
				assert_eq(k, -1, "非强制格 %s 应返回 -1，实际 %d" % [str(p), k])
				checked_free += 1
	assert_gt(checked_forced, 0, "应有至少一个被强制格可验证")


## unsat_core 与贪心口径一致：必要线索数应 ≤ 线索数（上界），且对必雷格 > 0。
func test_unsat_core_never_exceeds_clues() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	for seed in range(1, 5):
		var lv := PuzzleGenerator.new().generate_with_rules("classic", [], Vector2i(5, 5), 8, seed)
		if lv.is_empty():
			continue
		var board := Board.new()
		board.load_level(lv)
		var active := {}
		for rc in lv["revealed"]:
			var p := Vector2i(int(rc["c"]), int(rc["r"]))
			active[p] = board.grid.get_cell(p).value
		var total := int(lv["total_mines"])
		var classic: Object = RuleRegistry.default().resolve(&"classic")
		var oracle := RuleOracle.new(classic, [], Vector2i(5, 5), total)
		var spec := oracle.build_spec(active)
		var forced := RuleCpSat.find_forced_cells(spec)
		for m in forced.get("mine", []):
			var k := RuleCpSat.minimal_clue_count_unsat(spec, int(m[0]), int(m[1]))
			assert_true(k <= active.size() and k > 0,
				"seed %d 必雷格 %s 必要线索 %d 应 ∈ (0, %d]" % [seed, str(m), k, active.size()])
