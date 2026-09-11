extends GutTest

## P4「提示统一到约束原语」验证（v2.9.3）
##
## **收敛前**：内置变体的提示走旧 Def 路径，全局约束只特判了 MX/DT 两条，
## RL/QD/EP/4C/PF 全部漏掉；只有规则关卡才有完整约束推理。
##
## **收敛后**：内置变体与规则关卡统一走 `hint_rule`（RuleOracle + CP-SAT），
## 线索窗口与全局约束都从**同一套约束原语**出发生成 spec。
##
## 本测试证明两件事：① 映射完备（8 线索变体 + 7 全局约束全有对应规则）；
## ② 变体关卡设的全局约束**真的进入了 spec**（而不是被静默忽略）。


func test_variant_to_rule_covers_all_clue_variants() -> void:
	for v in [ClueEngine.Variant.CLASSIC, ClueEngine.Variant.N4, ClueEngine.Variant.SAME_COLOR,
			ClueEngine.Variant.CLOCK, ClueEngine.Variant.FR, ClueEngine.Variant.LOOP_RUNS,
			ClueEngine.Variant.DIST_SUM, ClueEngine.Variant.HV]:
		assert_true(HintSolver.VARIANT_TO_RULE.has(v), "线索变体 %d 应有规则映射" % v)
		if not HintSolver.VARIANT_TO_RULE.has(v):
			continue
		var rid: String = HintSolver.VARIANT_TO_RULE[v]
		var rule: Object = RuleRegistry.default().resolve(StringName(rid))
		assert_true(rule != null, "映射到的规则 %s 应已注册" % rid)
		if rule != null:
			assert_eq(rule.get_kind(), RulePlugin.KIND_CLUE, "%s 应是线索型规则" % rid)


func test_constraint_to_rule_covers_all_global_variants() -> void:
	for v in [ConstraintEngine.Variant.MX, ConstraintEngine.Variant.RL, ConstraintEngine.Variant.PF,
			ConstraintEngine.Variant.QD, ConstraintEngine.Variant.DT, ConstraintEngine.Variant.EP,
			ConstraintEngine.Variant.FOUR_COLOR]:
		assert_true(HintSolver.CONSTRAINT_TO_RULE.has(v), "全局约束 %d 应有规则映射" % v)
		if not HintSolver.CONSTRAINT_TO_RULE.has(v):
			continue
		var rid: String = HintSolver.CONSTRAINT_TO_RULE[v]
		var rule: Object = RuleRegistry.default().resolve(StringName(rid))
		assert_true(rule != null, "映射到的规则 %s 应已注册" % rid)
		if rule != null:
			assert_eq(rule.get_kind(), RulePlugin.KIND_GLOBAL, "%s 应是全局型规则" % rid)


## 变体关卡（非规则关卡）设的全局约束必须被收集进 spec。
## 这条是本次收敛的核心增量：收敛前 RL/QD/EP/4C/PF 在此处全部丢失。
func test_variant_level_globals_are_collected() -> void:
	var level := {
		"size": {"rows": 5, "cols": 5},
		"total_mines": 0,
		"mines": [],
		"revealed": [{"r": 2, "c": 2}],
	}
	var b := Board.new()
	b.load_level(level)
	b.clue_variant = ClueEngine.Variant.CLASSIC
	b.constraint_variant = -1
	b.constraint_variant2 = -1
	assert_eq(HintSolver.new()._resolve_globals(b).size(), 0, "未设全局约束时不应收集到任何全局规则")

	for v in [ConstraintEngine.Variant.MX, ConstraintEngine.Variant.RL, ConstraintEngine.Variant.PF,
			ConstraintEngine.Variant.QD, ConstraintEngine.Variant.EP, ConstraintEngine.Variant.FOUR_COLOR]:
		b.constraint_variant = v
		var gs: Array = HintSolver.new()._resolve_globals(b)
		assert_eq(gs.size(), 1, "约束 %d 应被收集为 1 条全局规则" % v)
		if gs.size() == 1:
			var want: String = HintSolver.CONSTRAINT_TO_RULE[v]
			assert_eq(str((gs[0] as Object).get_rule_id()), want, "收集到的应是 %s" % want)
		b.constraint_variant = -1


## 双布局（F 类）：两个全局约束都应被收集，且不重复。
func test_double_layout_collects_both_and_dedupes() -> void:
	var level := {
		"size": {"rows": 5, "cols": 5},
		"total_mines": 0,
		"mines": [],
		"revealed": [{"r": 2, "c": 2}],
	}
	var b := Board.new()
	b.load_level(level)
	b.constraint_variant = ConstraintEngine.Variant.MX
	b.constraint_variant2 = ConstraintEngine.Variant.EP
	var gs: Array = HintSolver.new()._resolve_globals(b)
	assert_eq(gs.size(), 2, "双布局应收集两条全局约束")

	# 同一个约束重复设两次不应被收集两遍
	b.constraint_variant2 = ConstraintEngine.Variant.MX
	var gs2: Array = HintSolver.new()._resolve_globals(b)
	assert_eq(gs2.size(), 1, "重复的同一约束应去重")


## 变体关卡（非规则关卡）走原语路径后，结论必须与真值一致。
## 注：不能用 0 雷盘做这个检验——`reveal_initial` 对 0 值格扩散，0 雷盘加载后整盘
## 已全部翻开，压根没有可推的隐藏格（这是既有语义，不是缺陷）。
func test_variant_level_hint_is_sound() -> void:
	var mine := Vector2i(0, 0)
	var level := {
		"size": {"rows": 4, "cols": 4},
		"total_mines": 1,
		"mines": [{"r": 0, "c": 0}],
		"revealed": [{"r": 3, "c": 3}],
	}
	var b := Board.new()
	b.load_level(level)
	b.clue_variant = ClueEngine.Variant.CLASSIC
	b.constraint_variant = ConstraintEngine.Variant.PF
	var steps: Array = HintSolver.new().hint(b)
	assert_gt(steps.size(), 0, "该盘面应有可推结论（雷已被逼出）")
	for st in steps:
		var step := st as ReasoningStep
		if step.state == "mine":
			assert_eq(step.pos, mine, "「必雷」结论只能在真雷位 (%d,%d)" % [mine.y, mine.x])
		elif step.state == "safe":
			assert_ne(step.pos, mine, "「必安」结论不得指向真雷位 (%d,%d)" % [mine.y, mine.x])
