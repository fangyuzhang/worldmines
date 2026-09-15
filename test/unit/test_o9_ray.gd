# test_o9_ray.gd —— O9「射距」单元测试（GUT）
# 覆盖：四方向首雷步数、min 语义、∞ 语义（全不通）、境界格（m=0 方向）、
# compute 与插件契约（无 0 值、不扩散、值域上限）。
extends GutTest

const MOD_DIR := "res://demo/mods/o9_sheju"


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod(MOD_DIR)


func _rule() -> Object:
	return RuleRegistry.default().resolve(&"o9")


func _mines(cells: Array) -> Dictionary:
	var s := {}
	for c in cells:
		s[Vector2i(int(c[0]), int(c[1]))] = true
	return s


func test_min_two_directions() -> void:
	# P=(2,2)：上 2 步、右 2 步 → min = 2
	var r: Object = _rule()
	var v: Variant = r.call("compute_clue", _mines([[2, 0], [4, 2]]), Vector2i(2, 2), Vector2i(5, 5))
	assert_eq(v, 2, "上/右各 2 步 → min=2")


func test_near_mine_wins() -> void:
	# P=(2,2)：上 1 步 (2,1) 与下 2 步 (2,4) → min = 1
	var r: Object = _rule()
	var v: Variant = r.call("compute_clue", _mines([[2, 1], [2, 4]]), Vector2i(2, 2), Vector2i(5, 5))
	assert_eq(v, 1, "近雷取最小")


func test_left_and_down() -> void:
	# P=(2,2)：左 1 步 (1,2)、下 2 步 (2,4) → min = 1
	var r: Object = _rule()
	var v: Variant = r.call("compute_clue", _mines([[1, 2], [2, 4]]), Vector2i(2, 2), Vector2i(5, 5))
	assert_eq(v, 1, "左 1 步取最小")


func test_infinity_when_no_mine_in_any_ray() -> void:
	# 空盘 → 四方向全不通 → "inf"
	var r: Object = _rule()
	var v: Variant = r.call("compute_clue", {}, Vector2i(2, 2), Vector2i(5, 5))
	assert_eq(str(v), "inf", "全不通 → ∞")


func test_corner_cell_m0_directions() -> void:
	# 角格 P=(0,0)：上/左方向 m=0；雷在正下 4 步 (0,4) → min = 4
	var r: Object = _rule()
	var v: Variant = r.call("compute_clue", _mines([[0, 4]]), Vector2i(0, 0), Vector2i(5, 5))
	assert_eq(v, 4, "角格仅剩余两方向，正下 4 步")


func test_diagonal_mine_not_counted() -> void:
	# 斜向雷不算（只有上/下/左/右四条射线）：P=(2,2) 雷在 (3,1) 斜角 → ∞
	var r: Object = _rule()
	var v: Variant = r.call("compute_clue", _mines([[3, 1]]), Vector2i(2, 2), Vector2i(5, 5))
	assert_eq(str(v), "inf", "斜角雷不在射线上")


func test_contracts() -> void:
	var r: Object = _rule()
	assert_eq(r.call("get_kind"), "clue", "KIND_CLUE")
	assert_false(bool(r.call("supports_mask")), "不支持遮蔽（离散码值）")
	# 无 0 值：任意盘任意格的结果不为 0
	var v: Variant = r.call("compute_clue", _mines([[2, 1]]), Vector2i(2, 2), Vector2i(5, 5))
	assert_ne(int(v), 0, "无 0 值")
	# 值域上限 = max(R,C) - 1
	assert_eq(int(r.call("value_upper_bound", Vector2i(5, 5))), 4, "5×5 上限 4")
	assert_eq(int(r.call("value_upper_bound", Vector2i(9, 9))), 8, "9×9 上限 8")
	# 不扩散
	var n: Array = r.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(5, 5), 2)
	assert_eq(n.size(), 0, "无 0 值不扩散")
