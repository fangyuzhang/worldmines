# test_board_global_constraints.gd —— Board 玩家视角全局约束入口测试（双视角隔离）
extends GutTest


func _make_board() -> Board:
	var b := Board.new()
	b.load_level({"size": {"rows": 3, "cols": 3}, "total_mines": 2, "mines": [{"r": 0, "c": 0}, {"r": 1, "c": 1}]})
	return b


func test_no_constraint() -> void:
	var b := _make_board()
	assert_eq(b.get_player_global_constraints().size(), 0, "无约束返回空数组")


func test_mx_constraint() -> void:
	var b := _make_board()
	b.set_variant(ClueEngine.Variant.CLASSIC, ConstraintEngine.Variant.MX)
	var cs := b.get_player_global_constraints()
	assert_eq(cs.size(), 1, "MX 返回一项")
	assert_eq(cs[0]["type"], "mx", "类型 mx")


func test_dt_constraint() -> void:
	var b := _make_board()
	var dominoes := [[{"c": 0, "r": 0}, {"c": 1, "r": 0}], [{"c": 0, "r": 1}, {"c": 1, "r": 1}]]
	b.set_variant(ClueEngine.Variant.CLASSIC, ConstraintEngine.Variant.DT, dominoes)
	var cs := b.get_player_global_constraints()
	assert_eq(cs.size(), 1, "DT 返回一项")
	assert_eq(cs[0]["type"], "dt", "类型 dt")
	assert_eq(cs[0]["dominoes"].size(), 2, "dominoes 两块")


func test_dual_constraint() -> void:
	var b := _make_board()
	b.set_variant(ClueEngine.Variant.CLASSIC, ConstraintEngine.Variant.MX, [], ConstraintEngine.Variant.EP)
	var cs := b.get_player_global_constraints()
	assert_eq(cs.size(), 2, "双约束返回两项")
	assert_eq(cs[0]["type"], "mx", "第一项 mx")
	assert_eq(cs[1]["type"], "ep", "第二项 ep")
