# test_precheck.gd —— 生成前可行性预筛测试
# 覆盖：可行组合通过 / UNSAT 组合（规则冗余、雷数不可达）快速拒绝 / 未知规则拒绝。
extends GutTest


func test_precheck_classic_feasible() -> void:
	var r := PuzzleGenerator.precheck_rules("classic", [], Vector2i(5, 5), 5)
	assert_true(bool(r["ok"]), "classic 5×5/5雷 应可行: %s" % str(r))


func test_precheck_4c_odd_mines_infeasible() -> void:
	# 四向守恒（黑格雷数相等）在 5 雷（奇数）下无整数解 → UNSAT
	var r := PuzzleGenerator.precheck_rules("classic", ["4c"], Vector2i(5, 5), 5)
	assert_false(bool(r["ok"]), "4C + 奇数雷 应不可行: %s" % str(r))


func test_precheck_4c_even_mines_feasible() -> void:
	var r := PuzzleGenerator.precheck_rules("classic", ["4c"], Vector2i(5, 5), 6)
	assert_true(bool(r["ok"]), "4C + 偶数雷 应可行: %s" % str(r))


func test_precheck_mx_feasible() -> void:
	var r := PuzzleGenerator.precheck_rules("classic", ["mx"], Vector2i(5, 5), 6)
	assert_true(bool(r["ok"]), "镜像 应可行: %s" % str(r))


func test_precheck_unknown_rule_rejected() -> void:
	var r := PuzzleGenerator.precheck_rules("classic", ["nonexistent_rule"], Vector2i(5, 5), 5)
	assert_false(bool(r["ok"]), "未知全局规则应拒绝")
