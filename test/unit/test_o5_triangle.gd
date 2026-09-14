extends GutTest

## O5「三角」算子测试（v3.0 S3）：golden 手算 + 契约（applies / 零扩散 / 值域）。

var _rule: Object


func before_all() -> void:
	var script: Variant = load("res://demo/mods/o5_sanjiao/entry.gd")
	var inst: Object = script.new()
	inst.call("on_load")
	_rule = RuleRegistry.default().resolve(&"o5")


func _ms(pairs: Array) -> Dictionary:
	var d := {}
	for p in pairs:
		d[Vector2i(int(p[0]), int(p[1]))] = true
	return d


func _val(mines: Array, pos: Vector2i, size: Vector2i) -> int:
	return int(_rule.call("compute_clue", _ms(mines), pos, size))


func test_registered_as_clue() -> void:
	assert_not_null(_rule, "o5 应已注册")
	assert_eq(str(_rule.call("get_kind")), "clue")


func test_empty_board_zero() -> void:
	assert_eq(_val([], Vector2i(2, 2), Vector2i(5, 5)), 0, "空盘 = 0")


func test_one_block_hit() -> void:
	# 5×5 (2,2)：p 为左上角的区块 = {(3,2),(2,3),(3,3)}——全雷 → 1
	assert_eq(_val([[3, 2], [2, 3], [3, 3]], Vector2i(2, 2), Vector2i(5, 5)), 1, "左上块全满 → 1")


func test_all_eight_mined() -> void:
	# 3×3 中心：八邻全雷 → 4 个区块全满 → f=4（GDD §4.3 强结论）
	var size := Vector2i(3, 3)
	var all8 := [[0, 0], [1, 0], [2, 0], [0, 1], [2, 1], [0, 2], [1, 2], [2, 2]]
	assert_eq(_val(all8, Vector2i(1, 1), size), 4, "八邻全雷 → 4 块全满 → 4")


func test_partial_hit() -> void:
	# 2 个区块各自全满 → 2：(3,2),(2,3),(3,3) + (1,2),(1,3),(2,3)【右上块】
	# p=(2,2) 右上角块 = {(-1,0),(-1,1),(0,1)} → {(1,2),(1,3),(2,3)}
	assert_eq(_val([[3, 2], [2, 3], [3, 3], [1, 2], [1, 3]], Vector2i(2, 2), Vector2i(5, 5)), 2, "两块全满 → 2")


func test_corner_single_block() -> void:
	# 角格 (0,0)：只有 1 个有效区块（p 左上角）={(1,0),(0,1),(1,1)}
	assert_eq(_val([[1, 0], [0, 1], [1, 1]], Vector2i(0, 0), Vector2i(5, 5)), 1, "角格 1 块全满 → 1")


func test_zero_not_diffused() -> void:
	var zs: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(5, 5), 0)
	assert_eq(zs.size(), 0, "三角 0 值不可扩散")


func test_applies_to_all() -> void:
	assert_true(bool(_rule.call("applies_to", Vector2i(0, 0), Vector2i(5, 5))))
	assert_true(bool(_rule.call("applies_to", Vector2i(2, 2), Vector2i(5, 5))))


func test_upper_bound() -> void:
	assert_eq(int(_rule.call("value_upper_bound", Vector2i(5, 5))), 4)


func test_mask_support() -> void:
	# v3.0 修订：遮蔽（问号）启用——区间语义 Σt ∈ [lo, hi]（计数型，直接线性）。
	# 注：现网生成器的遮蔽 interval 固定 [1, hi]，对值域 0-4 的规则弱化有限（难度实验记录在案）。
	assert_true(bool(_rule.call("supports_mask")), "遮蔽已启用（计数型区间编码）")


func test_interval_constraints_feasible() -> void:
	# 区间编码冒烟：角格 (0,0) 仅 1 个有效区块（Σt ≤ 1）
	# 区间 [1,4]（遮蔽语义采样）：可行（三格全雷即可）
	var oracle := RuleOracle.new(_rule, [], Vector2i(5, 5), 3, null)
	var spec1 := oracle.build_spec({Vector2i(0, 0): null}, [], {Vector2i(0, 0): Vector2i(1, 4)})
	assert_true(RuleCpSat.is_feasible(spec1), "角格 [1,4] 可行")
	# 区间 [3,4]：单区块上限 1——不可行
	var oracle2 := RuleOracle.new(_rule, [], Vector2i(5, 5), 3, null)
	var spec2 := oracle2.build_spec({Vector2i(0, 0): null}, [], {Vector2i(0, 0): Vector2i(3, 4)})
	assert_false(RuleCpSat.is_feasible(spec2), "角格 [3,4] 不可行（单区块上限 1）")
