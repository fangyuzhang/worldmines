# test_variant_levels_solvable.gd —— 变体关卡：正确加载变体 + 纯逻辑可解（plan1.9 §6.1）
# 覆盖 res://levels/ 下所有非 classic_ 关卡：断言 variant 字段被正确映射到
# clue_variant / constraint_variant，且完美玩家（Oracle 完备）能纯逻辑解出。
extends GutTest


func test_all_variant_levels_load_and_solve() -> void:
	var levels := LevelLoader.list_levels()
	var variant_count := 0
	for path in levels:
		if path.get_file().begins_with("classic_"):
			continue
		var data := _load_json(path)
		# generated_*.json 已迁移为 rule_level（clue_rule/global_rules，无 variant 字段），
		# 其加载与可解由 test_rule_platform 的规则关卡路径覆盖；这里只验证仍保留的内置 variant 关卡。
		if data.get("rule_level", false):
			continue
		variant_count += 1
		var board := LevelLoader.load_level(path)
		assert_not_null(board, "%s 应能加载" % path.get_file())
		if board == null:
			continue

		# 变体字段 → clue/constraint 映射正确（支持混合码 "布局+线索"）
		var code: String = str(data.get("variant", ""))
		var def := VariantRegistry.resolve(code)
		assert_false(def.is_empty(), "%s 未知变体码" % code)
		assert_eq(board.clue_variant, def.get("clue", -2), "%s clue_variant" % code)
		assert_eq(board.clue_variant2, int(def.get("clue2", -1)), "%s clue_variant2" % code)
		assert_eq(board.constraint_variant, def.get("constraint", -2), "%s constraint_variant" % code)
		assert_eq(board.constraint_variant2, int(def.get("constraint2", -1)), "%s constraint_variant2" % code)

		# 纯逻辑可解（完备 Oracle + 变体约束，含双布局第二约束 / 线索混合第二线索）
		var check := VariantConstraint.new(board.clue_variant, board.constraint_variant, board.dominoes, board.constraint_variant2, board.clue_variant2)
		var player := SolverPerfectPlayer.new()
		var result := player.solve(board, Callable(check, "check"))
		assert_true(result[0], "%s 应纯逻辑可解（%s 步）" % [path.get_file(), result[1]])

	# 当前 levels/ 下非 classic 关卡均为 rule_level（无内置 variant 关卡），variant_count 可为 0；
	# 规则关卡的可解性由 test_rule_platform 的生成闭环保证，本测试仅作未来 variant 关卡回归护栏。
	# 必须用 pending 显式跳过：只打印的话 GUT 会判「Did not assert」→ risky。
	if variant_count == 0:
		pending("当前无内置 variant 关卡（generated_* 已迁移为 rule_level），无可校验对象")
		return


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}
