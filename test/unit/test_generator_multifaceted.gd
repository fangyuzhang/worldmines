# test_generator_multifaceted.gd —— 生成器多角度测试
# 覆盖：
#   1. 自定义 mod 规则（三倍正交）单独生成 + 可解
#   2. mod 规则 + 内置全局约束混合（镜像/四象）
#   3. UNSAT 冲突规则被可行性预筛拦截（不暴力生成）
#   4. 多种内置 G+C 混合组合
#   5. 生成关卡质量：0 值格翻开、可解复验
extends GutTest


# ---- 自定义 mod 规则：三倍正交（线索 = 正交 4 格雷数 × 3）----
class TripleOrthoRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"triple_ortho"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "三倍正交", "rule_text": "数字 = 正交 4 格雷数 × 3（测试 mod 规则）"}

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return 3 * RulePlugin.count_dirs(mine_set, pos, grid_size, ClueEngine.orthogonal_dirs())

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var nbs := b.neighbors(pos, ClueEngine.orthogonal_dirs())
		b.add_eq(b.wsum([3, 3, 3, 3], b.cell_vars(nbs)), int(value))


# ---- 故意 UNSAT 的全局规则：黑格雷数 = 白格雷数 + 100（永远无解）----
class BrokenGlobalRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"broken_global"

	func get_kind() -> String:
		return KIND_GLOBAL

	func build_global_constraints(b: RuleBuilder) -> void:
		var black: Array = []
		var white: Array = []
		for r in b.rows:
			for c in b.cols:
				if (r + c) % 2 == 0:
					black.append(b.cell_var(r, c))
				else:
					white.append(b.cell_var(r, c))
		# 黑 = 白 + 100：5×5 黑 13 白 12，白+100 > 黑，恒 UNSAT
		b.add_eq(b.sum(black), CPIR.sum(white + [b.const_expr(100)]))


## 序贯可解复验（复用生成器同口径：forced-cell 检测推进到全盘确定）。
func _assert_solvable(clue_id: String, globals: Array, level: Dictionary) -> void:
	if level.is_empty():
		return
	var size := Vector2i(int(level["size"]["cols"]), int(level["size"]["rows"]))
	var total_mines := int(level["total_mines"])
	var reg := RuleRegistry.default()
	var clue: Object = reg.resolve(StringName(clue_id))
	var gs: Array = []
	for gid in globals:
		gs.append(reg.resolve(StringName(str(gid))))
	var oracle := RuleOracle.new(clue, gs, size, total_mines)
	# 用真实雷分布正向算线索值
	var mine_set := {}
	for m in level["mines"]:
		mine_set[Vector2i(int(m["c"]), int(m["r"]))] = true
	var values := {}
	for r in size.y:
		for c in size.x:
			var p := Vector2i(c, r)
			if not mine_set.has(p):
				values[p] = clue.compute_clue(mine_set, p, size)
	var active := {}
	for rc in level["revealed"]:
		var p := Vector2i(int(rc["c"]), int(rc["r"]))
		active[p] = values.get(p, null)
	var known_mines: Array[Vector2i] = []
	var total_cells := size.x * size.y
	var steps := 0
	while active.size() + known_mines.size() < total_cells:
		steps += 1
		if steps > total_cells + 8:
			assert_true(false, "%s+%s 序贯演绎步数超限" % [clue_id, str(globals)])
			return
		var forced := RuleCpSat.find_forced_cells(oracle.build_spec(active, known_mines))
		if forced.is_empty():
			assert_true(false, "%s+%s 序贯演绎无强制格（不可解）" % [clue_id, str(globals)])
			return
		var progressed := false
		for m in forced.get("mine", []):
			var p := Vector2i(int(m[1]), int(m[0]))
			if not known_mines.has(p):
				known_mines.append(p)
				progressed = true
		for s in forced.get("safe", []):
			var p := Vector2i(int(s[1]), int(s[0]))
			if not active.has(p):
				active[p] = values.get(p, null)
				progressed = true
		if not progressed:
			assert_true(false, "%s+%s 序贯演绎无进展" % [clue_id, str(globals)])
			return
	assert_true(known_mines.size() == total_mines, "%s+%s 序贯演绎应确定全部雷" % [clue_id, str(globals)])


func _setup() -> void:
	RuleRegistry.default().register(TripleOrthoRule.new())
	RuleRegistry.default().register(BrokenGlobalRule.new())


func test_mod_rule_generates() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	_setup()
	var pre := PuzzleGenerator.precheck_rules("triple_ortho", [], Vector2i(5, 5), 5)
	assert_true(bool(pre["ok"]), "三倍正交 5×5/5雷 应可行: %s" % str(pre))
	var level: Dictionary = PuzzleGenerator.new().generate_with_rules("triple_ortho", [], Vector2i(5, 5), 5, 42)
	assert_false(level.is_empty(), "三倍正交应生成关卡")
	if not level.is_empty():
		assert_eq(level["clue_rule"], "triple_ortho")
		_assert_solvable("triple_ortho", [], level)


func test_mod_mixed_with_builtin() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	_setup()
	# mod 线索规则 + 内置全局约束（镜像）：G+C 混合
	var pre := PuzzleGenerator.precheck_rules("triple_ortho", ["mx"], Vector2i(5, 5), 6)
	assert_true(bool(pre["ok"]), "三倍正交+镜像应可行: %s" % str(pre))
	var level: Dictionary = PuzzleGenerator.new().generate_with_rules("triple_ortho", ["mx"], Vector2i(5, 5), 6, 7)
	assert_false(level.is_empty(), "三倍正交+镜像应生成关卡")
	if not level.is_empty():
		_assert_solvable("triple_ortho", ["mx"], level)
	# 加载验证：线索值 = mod 规则正向计算
	var b := Board.new()
	b.load_level(level)
	assert_eq(b.rule_clue_id, "triple_ortho", "Board 应识别 mod 规则关卡")


func test_broken_rule_precheck_rejects() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	_setup()
	# UNSAT 冲突规则：预筛应立即拒绝（不暴力生成）
	var t0 := Time.get_ticks_msec()
	var pre := PuzzleGenerator.precheck_rules("classic", ["broken_global"], Vector2i(5, 5), 5)
	var dt := Time.get_ticks_msec() - t0
	assert_false(bool(pre["ok"]), "冲突规则应被预筛拒绝: %s" % str(pre))
	assert_true(dt < 3000, "预筛应快速拒绝（实测 %d ms，不应暴力生成）" % dt)


func test_various_builtin_mixes() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	# 多种 G+C 组合（GDD 兼容矩阵里的代表性组合）
	var combos := [
		["mx", "4n"],
		["qd", "distsum"],
		["ep", "sc"],
		["rl", "hv"],
	]
	for combo in combos:
		var g: String = combo[0]
		var c: String = combo[1]
		var pre := PuzzleGenerator.precheck_rules(c, [g], Vector2i(5, 5), 6)
		if not bool(pre["ok"]):
			push_warning("%s+%s 预筛不可行：%s" % [g, c, str(pre)])
			continue
		var level: Dictionary = PuzzleGenerator.new().generate_with_rules(c, [g], Vector2i(5, 5), 6, 3)
		assert_false(level.is_empty(), "%s+%s 应生成关卡" % [g, c])
		if not level.is_empty():
			_assert_solvable(c, [g], level)


func test_def_path_delegates_to_rules() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	# Def 路径现在委托规则平台：generate_from_def("4n", "mx") 等价 generate_with_rules("4n", ["mx"])
	var level: Dictionary = PuzzleGenerator.new().generate_from_def("4n", "mx", Vector2i(5, 5), 6, 5)
	assert_false(level.is_empty(), "Def 路径应生成关卡")
	if level.is_empty():
		return
	assert_eq(level["clue_rule"], "4n", "Def 线索应翻译为 4n")
	assert_eq(level["global_rules"], ["mx"], "Def 约束应翻译为 mx")
	_assert_solvable("4n", ["mx"], level)


func test_constructive_dt_routes_to_rules() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	# generate_constructive("dt") 现在走规则平台（DtRule 布雷 + dominoes 落盘）
	var level: Dictionary = PuzzleGenerator.new().generate_constructive("dt", Vector2i(5, 5), 6, 8)
	assert_false(level.is_empty(), "DT 构造式应生成")
	if level.is_empty():
		return
	assert_eq(level["clue_rule"], "classic", "DT 构造式线索应为 classic")
	assert_eq(level["global_rules"], ["dt"], "DT 构造式全局规则应为 [dt]")
	assert_true(level.has("dominoes"), "DT 构造式应落盘 dominoes")


func test_mixed_dt_routes_to_rules() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	# generate_mixed("dt", "4n") 现在走规则平台
	var level: Dictionary = PuzzleGenerator.new().generate_mixed("dt", "4n", Vector2i(5, 5), 6, 8)
	assert_false(level.is_empty(), "DT+4n 混合应生成")
	if level.is_empty():
		return
	assert_eq(level["clue_rule"], "4n", "DT+4n 线索应为 4n")
	assert_eq(level["global_rules"], ["dt"], "DT+4n 全局规则应为 [dt]")
	assert_true(level.has("dominoes"), "DT+4n 应落盘 dominoes")


func test_dt_level_dominoes_roundtrip() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	# 生成 DT 关卡：应落盘 dominoes 字段（此前新管线不落盘 → 加载后约束判定失效）
	var pre := PuzzleGenerator.precheck_rules("classic", ["dt"], Vector2i(5, 5), 6)
	assert_true(bool(pre["ok"]), "DT 5×5/6雷 应可行: %s" % str(pre))
	var level: Dictionary = PuzzleGenerator.new().generate_with_rules("classic", ["dt"], Vector2i(5, 5), 6, 21)
	assert_false(level.is_empty(), "DT 关卡应生成")
	if level.is_empty():
		return
	assert_true(level.has("dominoes"), "DT 关卡应落盘 dominoes 字段")
	assert_true(level["dominoes"].size() > 0, "dominoes 应非空")
	# 加载：Board 解析 + 同步给 DtRule（当前关卡的划分，而非上次生成的残留）
	var b := Board.new()
	b.load_level(level)
	assert_eq(b.dominoes.size(), level["dominoes"].size(), "Board 应解析骨牌")
	var dt: Object = RuleRegistry.default().resolve(&"dt")
	assert_eq(dt.get_dominoes().size(), b.dominoes.size(), "DtRule 应同步当前关卡的骨牌划分")
	# 约束判定：布雷应满足 DT（每骨牌至多 1 雷）
	var ms := {}
	for m in level["mines"]:
		ms[Vector2i(int(m["c"]), int(m["r"]))] = true
	assert_true(ConstraintEngine.check(ConstraintEngine.Variant.DT, ms, Vector2i(5, 5), {"dominoes": b.dominoes}),
		"DT 布雷应满足骨牌约束")


func test_generated_level_zero_cells_revealed() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var level: Dictionary = PuzzleGenerator.new().generate_with_rules("classic", ["mx"], Vector2i(5, 5), 6, 11)
	assert_false(level.is_empty(), "镜像关卡应生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)
	var mine_set := {}
	for m in level["mines"]:
		mine_set[Vector2i(int(m["c"]), int(m["r"]))] = true
	var found_zero := false
	for rc in level["revealed"]:
		var p := Vector2i(int(rc["c"]), int(rc["r"]))
		var cell: Cell = b.grid.get_cell(p)
		if cell != null and cell.value is int and int(cell.value) == 0:
			found_zero = true
			assert_eq(cell.state, Cell.State.REVEALED, "0 值格应翻开 @%s" % str(p))
	assert_true(found_zero, "应至少含一个 0 值格在 revealed 中")
