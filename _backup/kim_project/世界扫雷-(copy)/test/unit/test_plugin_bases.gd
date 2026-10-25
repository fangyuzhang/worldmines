# test_plugin_bases.gd —— CluePlugin / ConstraintPlugin 基类测试（文档 23 号 §3.1）
extends GutTest


class DiagSumClue extends CluePlugin:
	func get_clue_id() -> StringName:
		return &"C_DIAGSUM"
	func value_range(_gs: Vector2i) -> Vector2i:
		return Vector2i(0, 4)
	func compute(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		var n := 0
		for d in ClueEngine.diagonal_dirs():
			var p := pos + d
			if p.x >= 0 and p.x < grid_size.x and p.y >= 0 and p.y < grid_size.y and mine_set.has(p):
				n += 1
		return n


class EndpointEqual extends ConstraintPlugin:
	func get_constraint_id() -> StringName:
		return &"EP"
	func coupling_kind() -> int:
		return ConstraintPlugin.COUPLING_CAPACITY
	func check(mine_set: Dictionary, grid_size: Vector2i, _extra: Dictionary = {}) -> bool:
		if grid_size.x <= 1:
			return true
		var l := 0
		var r := 0
		for y in grid_size.y:
			if mine_set.has(Vector2i(0, y)):
				l += 1
			if mine_set.has(Vector2i(grid_size.x - 1, y)):
				r += 1
		return l == r


func test_clue_base_defaults() -> void:
	var p := CluePlugin.new()
	assert_eq(p.get_clue_id(), &"", "基类默认 clue_id 为空")
	assert_eq(p.value_range(Vector2i(5, 5)), Vector2i(0, 8), "基类默认值域 [0,8]")
	assert_true(p.is_zero_safe(), "基类默认 0 蕴含全安全")


func test_diag_sum_compute() -> void:
	var p := DiagSumClue.new()
	var gs := Vector2i(5, 5)
	# 中心 (2,2)，四个对角放置 2 雷
	var mines := {Vector2i(1, 1): true, Vector2i(3, 3): true}
	assert_eq(p.compute(mines, Vector2i(2, 2), gs), 2, "对角和应为 2")
	assert_eq(p.value_range(gs), Vector2i(0, 4), "对角和值域 [0,4]")


func test_diag_sum_neighbors_default() -> void:
	var p := DiagSumClue.new()
	var gs := Vector2i(5, 5)
	var nbs := p.clue_neighbors(Vector2i(2, 2), gs)
	assert_eq(nbs.size(), 8, "默认线索邻域应为 8 邻（中心格）")


func test_endpoint_equal_check() -> void:
	var c := EndpointEqual.new()
	var gs := Vector2i(5, 5)
	var ok_mines := {Vector2i(0, 0): true, Vector2i(4, 1): true}
	var bad_mines := {Vector2i(0, 0): true, Vector2i(0, 1): true}
	assert_true(c.check(ok_mines, gs), "左右各 1 雷应满足端点平衡")
	assert_false(c.check(bad_mines, gs), "左 2 右 0 应不满足端点平衡")
	assert_eq(c.coupling_kind(), ConstraintPlugin.COUPLING_CAPACITY, "端点平衡应为容量类")


func test_plugin_manager_integration() -> void:
	var pm := PluginManager.new()
	pm.declare_point(&"CluePlugin", ["get_clue_id", "value_range", "compute"])
	var clue := DiagSumClue.new()
	assert_true(pm.register(&"CluePlugin", clue), "CluePlugin 契约满足应注册成功")
	assert_eq(pm.first(&"CluePlugin"), clue, "应取到已注册线索插件")
	var con := EndpointEqual.new()
	pm.declare_point(&"ConstraintPlugin", ["get_constraint_id", "check", "coupling_kind"])
	assert_true(pm.register(&"ConstraintPlugin", con), "ConstraintPlugin 契约满足应注册成功")
	assert_eq(pm.first(&"ConstraintPlugin"), con, "应取到已注册约束插件")
