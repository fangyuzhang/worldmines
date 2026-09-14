extends GutTest

## O1「对穿」算子测试（v3.0 试点）：golden 手算 + 契约（applies_to / 零扩散 / 值域）。
## 注册走与 Mod 相同的 on_load 路径（不依赖 ModAPI autoload 在测试环境的可用性）。

var _rule: Object


func before_all() -> void:
	var script: Variant = load("res://demo/mods/o1_duichuan/entry.gd")
	var inst: Object = script.new()
	inst.call("on_load")
	_rule = RuleRegistry.default().resolve(&"o1")


func _ms(pairs: Array) -> Dictionary:
	var d := {}
	for p in pairs:
		d[Vector2i(int(p[0]), int(p[1]))] = true
	return d


func _val(mines: Array, pos: Vector2i, size: Vector2i) -> int:
	return int(_rule.call("compute_clue", _ms(mines), pos, size))


func test_registered_as_clue() -> void:
	assert_not_null(_rule, "o1 应已注册")
	assert_eq(str(_rule.call("get_kind")), "clue")


func test_golden_3x3_center() -> void:
	var size := Vector2i(3, 3)
	var c := Vector2i(1, 1)
	assert_eq(_val([], c, size), 0, "空盘 = 0")
	assert_eq(_val([[0, 1], [2, 1]], c, size), 1, "横轴两端 = 1")
	assert_eq(_val([[1, 0], [1, 2]], c, size), 1, "竖轴两端 = 1")
	assert_eq(_val([[0, 0], [2, 2]], c, size), 1, "主对角两端 = 1")
	assert_eq(_val([[2, 0], [0, 2]], c, size), 1, "副对角两端 = 1")
	assert_eq(_val([[0, 1], [2, 1], [0, 0], [2, 2]], c, size), 2, "两组轴 = 2")
	assert_eq(_val([[0, 0], [1, 0], [2, 0], [0, 1], [2, 1], [0, 2], [1, 2], [2, 2]], c, size), 4,
		"全 8 邻 = 4（四轴全中）")


func test_axis_endpoint_must_both_be_mines() -> void:
	# 单端是雷不成轴：{(0,1)} 只有一端 → 0
	assert_eq(_val([[0, 1]], Vector2i(1, 1), Vector2i(3, 3)), 0)


func test_applies_to_inner_only() -> void:
	var size := Vector2i(5, 5)
	assert_true(bool(_rule.call("applies_to", Vector2i(2, 2), size)), "中心是内部格")
	assert_true(bool(_rule.call("applies_to", Vector2i(1, 1), size)), "次外圈是内部格")
	assert_false(bool(_rule.call("applies_to", Vector2i(0, 2), size)), "最外圈不显示")
	assert_false(bool(_rule.call("applies_to", Vector2i(2, 4), size)), "最外圈不显示（下边）")


func test_zero_not_diffused() -> void:
	var dirs: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(5, 5), 0)
	assert_eq(dirs.size(), 0, "对穿 0 值不可扩散（GDD §4.3）")


func test_value_upper_bound() -> void:
	assert_eq(int(_rule.call("value_upper_bound", Vector2i(5, 5))), 4)


func test_no_mask_support() -> void:
	assert_false(bool(_rule.call("supports_mask")), "对穿不参与遮蔽（非计数型）")


func test_5x5_center_all_axes_complete() -> void:
	# 5×5 中心 (2,2) 四轴端点全部在盘内
	var size := Vector2i(5, 5)
	var c := Vector2i(2, 2)
	assert_eq(_val([[1, 2], [3, 2]], c, size), 1, "横 (1,2)-(3,2)")
	assert_eq(_val([[1, 1], [3, 3]], c, size), 1, "主对角 (1,1)-(3,3)")
	assert_eq(_val([[1, 3], [3, 1]], c, size), 1, "副对角 (1,3)-(3,1)")
