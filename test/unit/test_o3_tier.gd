extends GutTest

## O3「分档」算子测试（v3.0 S3）：golden 手算 + 契约（applies / 零扩散 / 值域）。
## 注册走与 Mod 相同的 on_load 路径。

var _rule: Object


func before_all() -> void:
	var script: Variant = load("res://demo/mods/o3_fendang/entry.gd")
	var inst: Object = script.new()
	inst.call("on_load")
	_rule = RuleRegistry.default().resolve(&"o3")


func _ms(pairs: Array) -> Dictionary:
	var d := {}
	for p in pairs:
		d[Vector2i(int(p[0]), int(p[1]))] = true
	return d


func _val(mines: Array, pos: Vector2i, size: Vector2i) -> int:
	return int(_rule.call("compute_clue", _ms(mines), pos, size))


func test_registered_as_clue() -> void:
	assert_not_null(_rule, "o3 应已注册")
	assert_eq(str(_rule.call("get_kind")), "clue")


func test_empty_board_zero() -> void:
	assert_eq(_val([], Vector2i(2, 2), Vector2i(5, 5)), 0, "空盘 = 档 0")


func test_tier_mapping() -> void:
	# 5×5 中心 (2,2)：八邻放不同数量雷，验证档位映射
	var size := Vector2i(5, 5)
	var c := Vector2i(2, 2)
	var nbrs := [[1, 1], [2, 1], [3, 1], [1, 2], [3, 2], [1, 3], [2, 3], [3, 3]]
	assert_eq(_val([nbrs[0]], c, size), 0, "1 雷 → 档 0")
	assert_eq(_val([nbrs[0], nbrs[1]], c, size), 1, "2 雷 → 档 1")
	assert_eq(_val([nbrs[0], nbrs[1], nbrs[2], nbrs[3]], c, size), 2, "4 雷 → 档 2")
	assert_eq(_val([nbrs[0], nbrs[1], nbrs[2], nbrs[3], nbrs[4], nbrs[5]], c, size), 3, "6 雷 → 档 3")


func test_8_mines_tier3() -> void:
	var size := Vector2i(3, 3)
	var mines: Array = []
	for r in 3:
		for cc in 3:
			if not (r == 1 and cc == 1):
				mines.append([cc, r])
	assert_eq(_val(mines, Vector2i(1, 1), size), 3, "8 邻全雷 → 档 3")


func test_corner_fewer_neighbors() -> void:
	# 角格 (0,0) 只有 3 个邻格：3 雷 → 档 1
	assert_eq(_val([[1, 0], [0, 1], [1, 1]], Vector2i(0, 0), Vector2i(5, 5)), 1, "角格 3 雷 → 档 1")


func test_zero_not_diffused() -> void:
	var zs: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(5, 5), 0)
	assert_eq(zs.size(), 0, "分档 0 值不可扩散")


func test_applies_to_all() -> void:
	assert_true(bool(_rule.call("applies_to", Vector2i(0, 0), Vector2i(5, 5))))
	assert_true(bool(_rule.call("applies_to", Vector2i(2, 2), Vector2i(5, 5))))


func test_upper_bound() -> void:
	assert_eq(int(_rule.call("value_upper_bound", Vector2i(5, 5))), 3)


func test_no_mask_support() -> void:
	assert_false(bool(_rule.call("supports_mask")), "本版不启用遮蔽")
