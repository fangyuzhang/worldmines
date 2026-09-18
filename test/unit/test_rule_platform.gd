# test_rule_platform.gd —— 自举式规则平台测试
# 覆盖：IR 原语求值（含说谎者 enforce 模式）/ 内置规则 dogfood 等价
# （IR ⟺ 旧引擎语义）/ C# 与 GDScript 双后端交叉对拍 /
# 骑士规则端到端生成（旧 Def 原子无法表达的规则）/ 第三方 mod 自举接入。
extends GutTest

const GS := Vector2i(5, 5)


func _random_mine_set(rng: RandomNumberGenerator, gsize: Vector2i, density: float) -> Dictionary:
	var ms := {}
	for r in gsize.y:
		for c in gsize.x:
			if rng.randf() < density:
				ms[Vector2i(c, r)] = true
	return ms


func _asg_from(mine_set: Dictionary) -> Dictionary:
	var asg := {}
	for p in mine_set:
		asg[CPIR.cell_key(p.y, p.x)] = 1
	return asg


func _aux_ids(aux_vars: Array) -> Array:
	var ids: Array = []
	for a in aux_vars:
		ids.append(int(a["i"]))
	return ids


# ==================== IR 原语求值 ====================

func test_ir_eval_basics() -> void:
	var c00 := CPIR.cell_var(0, 0)
	var c01 := CPIR.cell_var(0, 1)
	var c10 := CPIR.cell_var(1, 0)
	var asg := {
		CPIR.cell_key(0, 0): 1,
		CPIR.cell_key(0, 1): 0,
		CPIR.cell_key(1, 0): 1,
	}
	var s := CPIR.sum([c00, c01, c10])
	assert_true(CPIR.eval_constraint(CPIR.c_eq(s, CPIR.const_expr(2)), asg), "sum==2")
	assert_false(CPIR.eval_constraint(CPIR.c_le(s, CPIR.const_expr(1)), asg), "sum<=1 应为假")
	assert_true(CPIR.eval_constraint(CPIR.c_lt(CPIR.const_expr(1), s), asg), "1<sum")
	assert_true(CPIR.eval_constraint(CPIR.c_bool_or([c00, CPIR.not_lit(c00)]), asg), "bool_or")
	assert_true(CPIR.eval_constraint(CPIR.c_bool_and([c00, CPIR.not_lit(c01)]), asg), "bool_and")
	assert_true(CPIR.eval_constraint(CPIR.c_imp(c01, c00), asg), "imp: 前件假恒真")
	assert_true(CPIR.eval_constraint(CPIR.c_iff(c00, c10), asg), "iff: 1==1")
	assert_true(CPIR.eval_constraint(CPIR.c_all_diff([c00, c01]), asg), "all_diff: 1≠0")
	assert_false(CPIR.eval_constraint(CPIR.c_all_diff([c00, c10]), asg), "all_diff: 1==1 应假")
	# enforce：开关关 → 恒真；开关开 → 看内层
	var inner := CPIR.c_eq(s, CPIR.const_expr(5))
	assert_true(CPIR.eval_constraint(CPIR.c_enforce([c01], inner), asg), "开关关(0,1)=0 → 恒真")
	assert_false(CPIR.eval_constraint(CPIR.c_enforce([c00], inner), asg), "开关开(0,0)=1 → 内层假")
	# wsum
	var w := CPIR.wsum([2, 2, 2], [c00, c01, c10])
	assert_true(CPIR.eval_constraint(CPIR.c_eq(w, CPIR.const_expr(4)), asg), "wsum=2*2")


func test_ir_eval_liar_pattern() -> void:
	# 说谎者模式：两条线索恰一条可失效（aux 开关 + enforce + 计数）
	var b := RuleBuilder.new(2, 2)
	var lie1 := b.bool_var()
	var lie2 := b.bool_var()
	b.add_eq(b.sum(b.cell_vars([Vector2i(0, 0), Vector2i(1, 0)])), 2, [b.not_lit(lie1)])
	b.add_eq(b.sum(b.cell_vars([Vector2i(0, 1), Vector2i(1, 1)])), 2, [b.not_lit(lie2)])
	b.add_eq(b.sum([lie1, lie2]), 1)
	var aux_ids: Array = []
	for a in b.aux_vars:
		aux_ids.append(a["i"])
	# 情形 1：左线索假、右线索真 → 标记 lie1 即可满足
	var asg1 := {
		CPIR.cell_key(0, 0): 1, CPIR.cell_key(1, 0): 0,
		CPIR.cell_key(0, 1): 1, CPIR.cell_key(1, 1): 1,
	}
	assert_true(CPIR.eval_with_aux(b.constraints, asg1, aux_ids), "恰一条失效 → 可满足")
	# 情形 2：两条都假 → 无论怎么标记都剩一条被强制且为假
	var asg2 := _asg_from({})
	assert_false(CPIR.eval_with_aux(b.constraints, asg2, aux_ids), "两条全失效 → 不可满足")


# ==================== 内置规则 dogfood 等价（IR ⟺ 旧引擎） ====================

func test_clue_rules_ir_matches_compute() -> void:
	# 语义等价强测试：A 的全部线索值固化成 IR，在任意 B 下求值
	# ⟺ 每一格的线索值在 A/B 下完全一致。覆盖**当前在册的全部线索型规则**——
	# 遍历来源是变体目录（唯一事实源），不再写死 id 列表（写死的必然随变体池收敛而过期）。
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var reg := RuleRegistry.default()
	for rule_id in VariantCatalog.clue_ids():
		var rule: Object = reg.resolve(StringName(rule_id))
		for _t in 8:
			var a := _random_mine_set(rng, GS, 0.3)
			var bb := _random_mine_set(rng, GS, 0.3)
			var b := RuleBuilder.new(GS.y, GS.x)
			var cells: Array = []
			for r in GS.y:
				for c in GS.x:
					cells.append(Vector2i(c, r))
			for p in cells:
				rule.build_clue_constraints(b, p, rule.compute_clue(a, p, GS))
			var ir_true := CPIR.eval_all(b.constraints, _asg_from(bb))
			var expected := true
			for p in cells:
				if var_to_str(rule.compute_clue(bb, p, GS)) != var_to_str(rule.compute_clue(a, p, GS)):
					expected = false
					break
			assert_eq(ir_true, expected, "%s：IR 求值应与线索值一致" % rule_id)
			if ir_true != expected:
				return


func test_loopruns_ir_matches_compute() -> void:
	# loopruns 用 aux 表达「段起点」，需回溯 aux（单格 ≤8 个，可行）。逐格对拍。
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var reg := RuleRegistry.default()
	var rule: Object = reg.resolve(&"loopruns")
	for _t in 20:
		var a := _random_mine_set(rng, GS, 0.3)
		var bb := _random_mine_set(rng, GS, 0.3)
		for r in GS.y:
			for c in GS.x:
				var p := Vector2i(c, r)
				var b := RuleBuilder.new(GS.y, GS.x)
				rule.build_clue_constraints(b, p, rule.compute_clue(a, p, GS))
				var ir_true := CPIR.eval_with_aux(b.constraints, _asg_from(bb), _aux_ids(b.aux_vars))
				var expected := var_to_str(rule.compute_clue(bb, p, GS)) == var_to_str(rule.compute_clue(a, p, GS))
				assert_eq(ir_true, expected, "loopruns @ (%d,%d) IR 应与线索值一致" % [c, r])
				if ir_true != expected:
					return


func test_global_rules_ir_matches_engine() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var reg := RuleRegistry.default()
	# 无状态全局：mx/pf/rl/qd/ep/4c/total_mines（dt 见下，需骨牌）
	var pairs := [
		[&"mx", ConstraintEngine.Variant.MX],
		[&"pf", ConstraintEngine.Variant.PF],
		[&"qd", ConstraintEngine.Variant.QD],
		[&"ep", ConstraintEngine.Variant.EP],
		[&"4c", ConstraintEngine.Variant.FOUR_COLOR],
	]
	for pair in pairs:
		var rid: StringName = pair[0]
		var varint: int = pair[1]
		for _t in 20:
			var ms := _random_mine_set(rng, GS, 0.3)
			var asg := _asg_from(ms)
			var b := RuleBuilder.new(GS.y, GS.x)
			reg.resolve(rid).build_global_constraints(b)
			assert_eq(
				CPIR.eval_all(b.constraints, asg),
				ConstraintEngine.check(varint, ms, GS),
				"%s：IR 应与 ConstraintEngine 一致" % rid)
	# rl 用 aux 表达「差方向」，需回溯 aux（rows-1 个，可行）
	var brl := RuleBuilder.new(GS.y, GS.x)
	reg.resolve(&"rl").build_global_constraints(brl)
	var rl_ids := _aux_ids(brl.aux_vars)
	for _t2 in 20:
		var ms2 := _random_mine_set(rng, GS, 0.3)
		assert_eq(
			CPIR.eval_with_aux(brl.constraints, _asg_from(ms2), rl_ids),
			ConstraintEngine.check(ConstraintEngine.Variant.RL, ms2, GS),
			"rl：IR 应与 ConstraintEngine 一致")
	# total_mines
	var ms0 := _random_mine_set(rng, GS, 0.3)
	var total := ms0.size()
	var btm := RuleBuilder.new(GS.y, GS.x, total)
	reg.resolve(&"total_mines").build_global_constraints(btm)
	assert_true(CPIR.eval_all(btm.constraints, _asg_from(ms0)), "total_mines：自身雷数应满足")
	# dt（骨牌数据由规则 place_mines 生成并持有）
	var dt: Object = reg.resolve(&"dt")
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 3
	var dm: Array[Vector2i] = dt.place_mines(rng2, GS.x, GS.y, 5)
	if not dm.is_empty():
		var bdt := RuleBuilder.new(GS.y, GS.x)
		dt.build_global_constraints(bdt)
		for _t2 in 20:
			var ms4 := _random_mine_set(rng2, GS, 0.3)
			assert_eq(
				CPIR.eval_all(bdt.constraints, _asg_from(ms4)),
				ConstraintEngine.check(ConstraintEngine.Variant.DT, ms4, GS, {"dominoes": dt._dominoes}),
				"dt：IR 应与 ConstraintEngine 一致")


# ==================== 双后端交叉对拍（C# CP-SAT ⟷ GDScript 枚举） ====================

func test_csharp_tiny_unique() -> void:
	if not RuleCpSat.available():
		pending("C# RuleSolver 不可用（跳过）")
		return
	# 1×2：右格安全 + 总雷 1 → 左格必为雷，唯一解（排除解逻辑的最小探针）
	var spec := {
		"rows": 1, "cols": 2, "total_mines": 1,
		"safe_cells": [[0, 1]], "mine_cells": [],
		"clues": [], "globals": [], "aux": [], "timeout_ms": 5000,
	}
	assert_eq(RuleCpSat.count_solutions(spec), 1, "1×2 应唯一解")
	assert_eq(RuleCpSat.fallback_count(spec), 1, "回退枚举应一致")
	# 4 自由格 + 总雷 4（全雷，必唯一）——复现 knight 全展开场景
	var spec2 := {
		"rows": 1, "cols": 5, "total_mines": 4,
		"safe_cells": [[0, 4]], "mine_cells": [],
		"clues": [], "globals": [], "aux": [], "timeout_ms": 5000,
	}
	assert_eq(RuleCpSat.count_solutions(spec2), 1, "4 自由格全雷应唯一")


func test_csharp_matches_fallback() -> void:
	if not RuleCpSat.available():
		pending("C# RuleSolver 不可用（跳过对拍）")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var reg := RuleRegistry.default()
	var classic: Object = reg.resolve(&"classic")
	var mx: Object = reg.resolve(&"mx")
	for t in 8:
		var total := 3 + (t % 3)
		var globals: Array = [] if t % 2 == 0 else [mx]
		var oracle := RuleOracle.new(classic, globals, GS, total)
		var ms := _random_mine_set(rng, GS, 0.2)
		# 随机激活 4 条线索（值来自 ms）
		var cells: Array = []
		for r in GS.y:
			for c in GS.x:
				cells.append(Vector2i(c, r))
		cells.shuffle()
		var active := {}
		for i in mini(4, cells.size()):
			var p: Vector2i = cells[i]
			if not ms.has(p):
				active[p] = classic.compute_clue(ms, p, GS)
		var spec := oracle.build_spec(active)
		var cs := RuleCpSat.count_solutions(spec)
		var fb := RuleCpSat.fallback_count(spec)
		assert_eq(cs, fb, "C# 与 GDScript 计数应一致（trial %d）" % t)


# ==================== 端到端生成 ====================

func _try_generate(rule_id: String, globals: Array, size: Vector2i, mines: int, seeds := 10) -> Dictionary:
	var gen := PuzzleGenerator.new()
	for seed in range(1, seeds + 1):
		var level := gen.generate_with_rules(rule_id, globals, size, mines, seed)
		if not level.is_empty():
			return level
	return {}


func test_generate_knight_end_to_end() -> void:
	# 骑士规则：旧 Def IR（固定 6 窗口原子）无法表达 → 自举性实证
	var level := _try_generate("knight", [], Vector2i(5, 5), 4)
	assert_false(level.is_empty(), "骑士规则应能在 10 个种子内生成")
	if level.is_empty():
		return
	assert_true(level.get("rule_level", false), "规则关卡标记")
	assert_eq(level["clue_rule"], "knight")
	assert_true(level["revealed"].size() > 0, "应有初始线索")
	# 可解性复验（R01 真义：序贯纯逻辑可解，非静态唯一）
	_assert_solvable("knight", [], level)


func test_generate_classic_with_total() -> void:
	var level := _try_generate("classic", ["total_mines"], Vector2i(5, 5), 5)
	assert_false(level.is_empty(), "classic+total_mines 应能生成")
	if level.is_empty():
		return
	assert_eq(level["clue_rule"], "classic")
	assert_eq(level["global_rules"], ["total_mines"])


func test_generate_knight_mx() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（回退枚举太慢，跳过）")
		return
	# 骑士线索 + 镜像布局：第三方无从下手的组合，平台内自由组合
	var level := _try_generate("knight", ["mx"], Vector2i(5, 5), 5)
	assert_false(level.is_empty(), "knight+mx 应能生成")
	if level.is_empty():
		return
	# 镜像复验
	var mines: Array[Vector2i] = []
	for m in level["mines"]:
		mines.append(Vector2i(int(m["c"]), int(m["r"])))
	var ms := {}
	for m in mines:
		ms[m] = true
	assert_true(ConstraintEngine.check(ConstraintEngine.Variant.MX, ms, Vector2i(5, 5)), "生成雷区应满足镜像")


## 可解性复验（R01 真义）：初始线索下应「序贯纯逻辑可解」。
## 不用静态唯一：0 值格不作为初始线索后，静态多解是正常现象（v2.8.3 口径）。
## 统一走 ProofLog.build（玩家视角序贯演绎 + 确证雷不动点），不再各自实现 forced-cell 循环。
func _assert_solvable(clue_id: String, global_ids: Array, level: Dictionary) -> void:
	var log: Dictionary = ProofLog.build(level)
	assert_true(bool(log.get("solved", false)),
		"%s+%s 序贯演绎不可解：%s" % [clue_id, str(global_ids), log.get("reason", "")])


func test_generate_all_clue_rules() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	# 遍历**官方观测轴**（静态常量 = GDD 口径），而不是「注册表里所有 clue」：
	# 后者会把其它测试残留注册的试验规则也卷进来，用例顺序一变就误报
	# （2026-09-18：某文件注册的 broken_global 残留下来，让本测试断言「应能生成」失败）。
	# 尺寸口径按 GDD §8.2：变径 o4 在 5×5 **停用**——中心格半径 2 邻域恰为全盘去心，
	# 其数字恒等于总雷数（直接泄密），故不参与 5×5 小盘遍历。
	for rule_id in VariantCatalog.OBS_IDS:
		if rule_id == "o4":
			continue
		var level := _try_generate(rule_id, [], Vector2i(5, 5), 4, 8)
		assert_false(level.is_empty(), "%s 应能在 8 个种子内生成" % rule_id)
		if level.is_empty():
			continue
		assert_eq(level["clue_rule"], rule_id)
		_assert_solvable(rule_id, [], level)


func test_generate_global_rules() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	# 遍历**官方结构 + 守恒轴**（静态常量），同样避开注册表里的残留试验规则。
	# dt 骨牌为实例状态，只验证可生成不做唯一复验；z5 等差行带整除契约（GDD §8.1：
	# 7×7 需 7 的倍数雷），5×5 / 4 雷本就不满足 → 它单列验证，不在此循环。
	for gid in VariantCatalog.mixed_global_ids() + VariantCatalog.mixed_conserve_ids() + ["dt"]:
		if gid == "z5":
			continue
		var level := _try_generate("classic", [gid], Vector2i(5, 5), 4, 8)
		assert_false(level.is_empty(), "classic+%s 应能在 8 个种子内生成" % gid)
		if level.is_empty():
			continue
		assert_eq(level["global_rules"], [gid])
		if gid != "dt":
			_assert_solvable("classic", [gid], level)


func test_qd_even_board_consistent() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（回退枚举太慢，跳过）")
		return
	# 偶数盘四象：无中轴 → 四象限均分。历史 bug：生成器布雷放中轴、校验器把中轴算进右下象限，
	# 导致偶数盘生成必然失败（静默返回空）。锁定：生成非空 + 布雷满足四象约束 + 序贯可解。
	var level := _try_generate("classic", ["qd"], Vector2i(6, 6), 8, 20)
	assert_false(level.is_empty(), "偶数盘 classic+qd 应能生成")
	if level.is_empty():
		return
	var ms := {}
	for m in level["mines"]:
		ms[Vector2i(int(m["c"]), int(m["r"]))] = true
	assert_true(ConstraintEngine.check(ConstraintEngine.Variant.QD, ms, Vector2i(6, 6)), "偶数盘布雷应满足四象约束")
	_assert_solvable("classic", ["qd"], level)


# ==================== 第三方 mod 自举接入 ====================

func test_mod_bootstrap_rule() -> void:
	# 完整链路：manifest → entry → on_load 注册 → 生成端到端
	var api := preload("res://core/mod_api.gd").new()
	var r := api.load_mod("res://demo/mods/custom_rule_mod")
	assert_true(r.get("ok", false), "mod 应加载成功: %s" % str(r.get("reason", "")))
	if not r.get("ok", false):
		return
	var reg := RuleRegistry.default()
	assert_true(reg.all_ids().has("x2diag"), "on_load 应注册 x2diag 规则")
	var level := _try_generate("x2diag", [], Vector2i(5, 5), 4)
	assert_false(level.is_empty(), "mod 规则应能生成关卡")
	if not level.is_empty():
		assert_eq(level["clue_rule"], "x2diag")
	# P0-T5：卸载应清理该 mod 注册的规则（此前只能 reset 全清，现精确清理）
	var ur := api.unload_mod("custom_rule_mod")
	assert_true(ur.get("ok", false), "卸载应成功")
	assert_false(reg.all_ids().has("x2diag"), "卸载后 x2diag 应被清理")
	api.reset()


func test_board_plays_rule_level() -> void:
	# 游玩闭环：生成的规则关卡能被 Board 加载、线索值正确、可翻开至胜利
	var level := _try_generate("knight", [], Vector2i(5, 5), 4)
	assert_false(level.is_empty(), "应有可生成的骑士关卡")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)
	assert_eq(b.rule_clue_id, "knight", "Board 应识别规则关卡")
	var rule: Object = RuleRegistry.default().resolve(&"knight")
	var size := b.grid.size()
	var ms := {}
	for m in b._static_mines:
		ms[m] = true
	for r in size.y:
		for c in size.x:
			var p := Vector2i(c, r)
			if ms.has(p):
				continue
			assert_eq(b.grid.get_cell(p).value, rule.compute_clue(ms, p, size), "线索值应等于规则正向计算")
	# 翻开全部非雷格 → 胜利
	for r in size.y:
		for c in size.x:
			var p := Vector2i(c, r)
			if not ms.has(p):
				b.reveal(p)
	assert_eq(b.state, Board.GameState.WON, "翻完非雷格应胜利（规则关卡胜负判定复用）")


func test_board_zero_flood_uses_rule_window() -> void:
	# 扩散语义测试：直接调 reveal() 触发扩散（load_level 用 reveal_initial 不扩散）。
	# 骑士规则：中心无骑士邻 → 只翻中心；经典规则：8 邻 → 全翻。
	var knight_level := {
		"rule_level": true, "clue_rule": "knight",
		"size": {"rows": 3, "cols": 3}, "total_mines": 0,
		"mines": [], "revealed": [],
	}
	var bk := Board.new()
	bk.load_level(knight_level)
	bk.reveal(Vector2i(1, 1))
	var revealed_k := 0
	for r in 3:
		for c in 3:
			if bk.grid.get_cell(Vector2i(c, r)).state == Cell.State.REVEALED:
				revealed_k += 1
	assert_eq(revealed_k, 1, "骑士规则：中心无骑士邻，应只翻中心（不按 8 邻扩散）")

	var classic_level := {
		"rule_level": true, "clue_rule": "classic",
		"size": {"rows": 3, "cols": 3}, "total_mines": 0,
		"mines": [], "revealed": [],
	}
	var bc := Board.new()
	bc.load_level(classic_level)
	bc.reveal(Vector2i(1, 1))
	var revealed_c := 0
	for r in 3:
		for c in 3:
			if bc.grid.get_cell(Vector2i(c, r)).state == Cell.State.REVEALED:
				revealed_c += 1
	assert_eq(revealed_c, 9, "经典规则：0 值 8 邻扩散，应全翻")


func test_load_level_zero_reveals() -> void:
	# 回归：0 值格（空格）现在正确翻开（不再保持 HIDDEN 成为孤立空白可点击格）。
	# 复现用户反复报告的 bug：残局关里 0 值格显示为「什么都没有但可点击」。
	var level := {
		"rule_level": true, "clue_rule": "classic",
		"size": {"rows": 5, "cols": 5}, "total_mines": 10,
		"mines": [
			{"r": 0, "c": 0}, {"r": 0, "c": 1}, {"r": 0, "c": 2},
			{"r": 1, "c": 0}, {"r": 1, "c": 4}, {"r": 2, "c": 2},
			{"r": 2, "c": 4}, {"r": 3, "c": 2}, {"r": 3, "c": 3}, {"r": 4, "c": 4},
		],
		"revealed": [
			{"r": 0, "c": 4, "value": 1},
			{"r": 2, "c": 3, "value": 5},
			{"r": 4, "c": 2, "value": 2},
			{"r": 4, "c": 3, "value": 3},
			{"r": 3, "c": 0, "value": 0},
		],
	}
	var b := Board.new()
	b.load_level(level)
	# value=0 的初始格（第 4 行第 1 列）现在正确翻开（不再是孤立空白 HIDDEN）
	var zero_cell := b.grid.get_cell(Vector2i(0, 3))
	assert_eq(zero_cell.state, Cell.State.REVEALED, "0 值格应正确翻开（不再孤立空白可点击）")
	assert_eq(int(zero_cell.value), 0, "0 值格值应为 0")


func test_load_level_generated_zero_reveals() -> void:
	# 回归：生成关（rule_level 格式）的 revealed 无 value 字段，0 值格由 _compute_clues 算好。
	# 复现 generated_02 场景：(4,4) 是 8 邻无雷的 0 格，加载后必须正确翻开
	#（不再保持 HIDDEN 成为孤立空白可点击格）。
	var level := {
		"rule_level": true, "clue_rule": "classic", "global_rules": [],
		"size": {"rows": 5, "cols": 5}, "total_mines": 7,
		"mines": [
			{"c": 0, "r": 3}, {"c": 3, "r": 2}, {"c": 2, "r": 3}, {"c": 0, "r": 1},
			{"c": 0, "r": 0}, {"c": 3, "r": 0}, {"c": 1, "r": 2},
		],
		"revealed": [
			{"c": 4, "r": 0}, {"c": 2, "r": 1}, {"c": 0, "r": 2}, {"c": 4, "r": 2},
			{"c": 1, "r": 3}, {"c": 4, "r": 3, "interval": [1, 8]},
			{"c": 1, "r": 4}, {"c": 2, "r": 4}, {"c": 4, "r": 4},
		],
	}
	var b := Board.new()
	b.load_level(level)
	# (4,4) 是 0 值格，现在正确翻开（不再保持 HIDDEN）
	assert_eq(b.grid.get_cell(Vector2i(4, 4)).state, Cell.State.REVEALED,
		"生成关 value=0 的初始格应正确翻开（不再孤立空白）")
	assert_eq(int(b.grid.get_cell(Vector2i(4, 4)).value), 0, "0 值格值应为 0")
	# 问号格 (4,3) 正常翻开 + 遮蔽区间
	assert_eq(b.grid.get_cell(Vector2i(4, 3)).state, Cell.State.REVEALED, "问号格应翻开")
	assert_eq(b.grid.get_cell(Vector2i(4, 3)).hidden_interval, Vector2i(1, 8), "问号格遮蔽区间正确")
	# 数字格 (4,0) 翻开且值 = 1
	assert_eq(b.grid.get_cell(Vector2i(4, 0)).state, Cell.State.REVEALED, "数字格应翻开")
	assert_eq(int(b.grid.get_cell(Vector2i(4, 0)).value), 1, "数字格值正确")


func test_generated_level_zero_cells_revealed() -> void:
	# 端到端回归：生成关卡后，0 值格（空格）应正确翻开，不再是「孤立的空白可点击格」。
	# 这是用户反复报告 bug 的根源锁（此前生成器排除 0 值格 → 残局关孤立空白）。
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate("classic", ["mx"], Vector2i(5, 5), 6)
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
			assert_eq(cell.state, Cell.State.REVEALED, "0 值格应正确翻开 @%s（不再孤立空白）" % str(p))
	assert_true(found_zero, "本关应至少含一个 0 值格在 revealed 中（生成器已不再排除 0 值格）")


func test_int_aux_blackbox_eval() -> void:
	# P3：int_var 现在能在 GDScript 黑盒求值里工作（此前 C# only）
	var b := RuleBuilder.new(3, 3, 2)
	var x := b.int_var(0, 3)  # 整数 aux，域 [0,3]
	b.add_eq(x, 2)  # 约束 x == 2
	var asg := {}
	assert_true(CPIR.eval_with_aux(b.constraints, asg, b.aux_vars), "int aux 黑盒求值应能找到 x=2 的解")
	assert_eq(int(asg.get(CPIR.aux_key(0), -1)), 2, "x 应为 2")
	# 无解：x == 5 超出域 [0,3]，应判不满足
	var b2 := RuleBuilder.new(3, 3, 2)
	var x2 := b2.int_var(0, 3)
	b2.add_eq(x2, 5)
	assert_false(CPIR.eval_with_aux(b2.constraints, {}, b2.aux_vars), "x=5 超出域应判不满足")


func test_registry_builtin_vs_custom() -> void:
	# 自举式平台：内置规则 vs mod 注册规则的区分（mod_select UI 依赖 custom_ids）
	var reg := RuleRegistry.default()
	var bi := reg.builtin_ids()
	assert_true(bi.has("classic"), "内置应含 classic")
	# knight 已于 2026-09-18 移出内置表（收进 demo/mods/legacy_rules；测试进程由 _pre_run 装配）
	# → 它现在是 **mod 身份**：应落在 custom_ids 而不是 builtin_ids。
	assert_false(bi.has("knight"), "knight 已移出内置表（备用包以 mod 身份提供）")
	assert_true(reg.custom_ids().has("knight"), "knight 应作为 mod 注册规则出现")
	assert_true(reg.resolve(&"knight") != null, "knight 仍须可用（引擎原语仍按 id 工作）")
	assert_false(reg.custom_ids().has("classic"), "custom 不应含内置 classic")
	reg.register(HarvestDemoRule.new())
	assert_true(reg.custom_ids().has("harvest_demo"), "custom 应包含 mod 注册的规则")


func test_registry_harvest_from_plugin_manager() -> void:
	# ModAPI 扩展点路径：register_extension(&"rules", ...) → harvest 收割
	var pm := PluginManager.new()
	pm.declare_point(RuleRegistry.EXTENSION_POINT, RuleRegistry.CONTRACT)
	# 注册一个内联规则进 pm（模拟 mod 经 ModAPI 注册）
	var rule := HarvestDemoRule.new()
	assert_true(pm.register(RuleRegistry.EXTENSION_POINT, rule), "契约校验应通过")
	var reg := RuleRegistry.new()
	reg.harvest(pm)
	assert_false(reg.resolve(&"harvest_demo") == null, "harvest 应收割扩展点规则")


# ==================== 异形拓扑（A2）：双后端对拍 / 洞格约束 / 序贯可解 ====================

const TOPO_2X3 := {
	"positions": [
		{"x": 0, "y": 0}, {"x": 1, "y": 0}, {"x": 2, "y": 0},
		{"x": 0, "y": 1}, {"x": 1, "y": 1}, {"x": 2, "y": 1},
	],
	"adjacency": [
		{"a": {"x": 0, "y": 0}, "b": {"x": 1, "y": 0}},
		{"a": {"x": 1, "y": 0}, "b": {"x": 2, "y": 0}},
		{"a": {"x": 0, "y": 0}, "b": {"x": 0, "y": 1}},
		{"a": {"x": 1, "y": 0}, "b": {"x": 1, "y": 1}},
		{"a": {"x": 2, "y": 0}, "b": {"x": 2, "y": 1}},
		{"a": {"x": 0, "y": 1}, "b": {"x": 1, "y": 1}},
		{"a": {"x": 1, "y": 1}, "b": {"x": 2, "y": 1}},
	]
}


static func _make_topo(topo_dict: Dictionary) -> AdjacencyGrid:
	var t := AdjacencyGrid.new()
	t.setup_from_topo(topo_dict)
	return t


## 3×2 包围盒去掉 (1,0) → 5 格，(1,0) 为洞格（验证洞格被 CP-SAT 排除）。
static func _topo_with_hole() -> AdjacencyGrid:
	return _make_topo({
		"positions": [
			{"x": 0, "y": 0}, {"x": 2, "y": 0},
			{"x": 0, "y": 1}, {"x": 1, "y": 1}, {"x": 2, "y": 1},
		],
		"adjacency": [
			{"a": {"x": 0, "y": 0}, "b": {"x": 0, "y": 1}},
			{"a": {"x": 2, "y": 0}, "b": {"x": 2, "y": 1}},
			{"a": {"x": 0, "y": 1}, "b": {"x": 1, "y": 1}},
			{"a": {"x": 1, "y": 1}, "b": {"x": 2, "y": 1}},
		]
	})


## 拓扑邻域计数（测试侧独立实现，与 Board._count_adj_mines 交叉对拍）。
static func _topo_clue(mine_set: Dictionary, topo: GridInterface, pos: Vector2i) -> int:
	var n := 0
	for nb in topo.get_neighbors(pos):
		if mine_set.has(nb):
			n += 1
	return n


func test_topo_csharp_matches_fallback() -> void:
	if not RuleCpSat.available():
		pending("C# RuleSolver 不可用（跳过对拍）")
		return
	var topo := _topo_with_hole()
	assert_eq(topo.cell_count(), 5, "拓扑应含 5 格（洞格不计）")
	assert_false(topo.in_board(Vector2i(1, 0)), "(1,0) 应为洞格")
	var classic: Object = RuleRegistry.default().resolve(&"classic")
	var oracle := RuleOracle.new(classic, [], Vector2i(3, 2), 1, topo)
	# (0,1) 邻域 {(0,0),(1,1)}=1；(2,1) 邻域 {(1,1),(2,0)}=0
	# → (1,1)=(2,0)=0 → (0,0)=1，总雷 1 → 唯一解。
	var spec := oracle.build_spec({Vector2i(0, 1): 1, Vector2i(2, 1): 0})
	var has_hole := false
	for s in spec["safe_cells"]:
		if int(s[0]) == 0 and int(s[1]) == 1:
			has_hole = true
	assert_true(has_hole, "洞格 (c=1,r=0) 应进 safe_cells（约束为非雷）")
	assert_eq(RuleCpSat.fallback_count(spec), 1, "GDScript 枚举：异形应唯一解")
	assert_eq(RuleCpSat.count_solutions(spec), 1, "C# CP-SAT 与 GDScript 应一致（异形唯一解）")


func _assert_solvable_topo(level: Dictionary, topo: GridInterface) -> void:
	var size := Vector2i(int(level["size"]["cols"]), int(level["size"]["rows"]))
	var total_mines := int(level["total_mines"])
	var clue: Object = RuleRegistry.default().resolve(&"classic")
	var oracle := RuleOracle.new(clue, [], size, total_mines, topo)
	var mine_set := {}
	for m in level["mines"]:
		mine_set[Vector2i(int(m["c"]), int(m["r"]))] = true
	var values := {}
	for p in topo.all_positions():
		if mine_set.has(p):
			continue
		values[p] = _topo_clue(mine_set, topo, p)
	var active := {}
	for rc in level["revealed"]:
		var p := Vector2i(int(rc["c"]), int(rc["r"]))
		# 与 board.load_level 同口径：0 值格也进初始翻开集（不再跳过）。
		active[p] = values.get(p, null)
	var known_mines: Array[Vector2i] = []
	var total_cells := topo.cell_count()
	var steps := 0
	while active.size() + known_mines.size() < total_cells:
		steps += 1
		if steps > total_cells + 8:
			assert_true(false, "异形序贯演绎步数超限（不可解）")
			return
		var forced := RuleCpSat.find_forced_cells(oracle.build_spec(active, known_mines))
		if forced.is_empty():
			assert_true(false, "异形序贯演绎中途无强制格（真二选一，不可解）")
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
			assert_true(false, "异形序贯演绎无进展")
			return
	assert_eq(known_mines.size(), total_mines, "异形序贯演绎应确定全部雷")


func test_topo_generate_is_stepwise_solvable() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var r := SeedRecipe.new()
	r.seed = 5
	r.topology_kind = "adjacency"
	r.clue_rule_id = "classic"
	r.mine_count = 2
	r.topology_params = TOPO_2X3.duplicate(true)
	var level := LevelGenerator.new().generate(r)
	assert_false(level.is_empty(), "异形关卡应生成")
	if level.is_empty():
		return
	_assert_solvable_topo(level, _make_topo(level["topology"]))


func test_topo_forces_classic_clue() -> void:
	# Bug A 回归：异形邻域由邻接表定义，方向型变体（knight）的 dirs 窗口无意义。
	# 正向邻域计数 + 约束方向窗口会自相矛盾 → 静默生成失败。现强制 classic。
	var r := SeedRecipe.new()
	r.seed = 5
	r.topology_kind = "adjacency"
	r.clue_rule_id = "knight"
	r.mine_count = 2
	r.topology_params = TOPO_2X3.duplicate(true)
	var level := LevelGenerator.new().generate(r)
	assert_false(level.is_empty(), "异形下非 classic 应被强制为 classic 并成功生成")
	if level.is_empty():
		return
	assert_eq(level["clue_rule"], "classic", "异形关卡线索规则应为 classic")


func test_topo_clue_matches_board() -> void:
	# 跨模块交叉：生成口径（拓扑邻域计数）⟷ Board 加载 _count_adj_mines
	var r := SeedRecipe.new()
	r.seed = 5
	r.topology_kind = "adjacency"
	r.clue_rule_id = "classic"
	r.mine_count = 2
	r.topology_params = TOPO_2X3.duplicate(true)
	var level := LevelGenerator.new().generate(r)
	assert_false(level.is_empty(), "异形关卡应生成")
	if level.is_empty():
		return
	var board := Board.new()
	board.load_level(level)
	var topo := _make_topo(level["topology"])
	var mine_set := {}
	for m in level["mines"]:
		mine_set[Vector2i(int(m["c"]), int(m["r"]))] = true
	for p in topo.all_positions():
		if mine_set.has(p):
			continue
		assert_eq(board.grid.get_cell(p).value, _topo_clue(mine_set, topo, p),
			"Board 线索值应与拓扑邻域计数一致 @%s" % str(p))


class HarvestDemoRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"harvest_demo"

	func get_kind() -> String:
		return KIND_CLUE

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return RulePlugin.count_dirs(mine_set, pos, grid_size, ClueEngine.ring_dirs())

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var nbs := b.neighbors(pos, ClueEngine.ring_dirs())
		b.add_eq(b.sum(b.cell_vars(nbs)), int(value))
