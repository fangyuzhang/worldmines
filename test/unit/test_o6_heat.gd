extends GutTest

## O6「热度」算子测试（v3.0 S3）：golden 手算 + 契约（applies / 零扩散可扩散 / 值域）。

var _rule: Object


func before_all() -> void:
	var script: Variant = load("res://demo/mods/o6_redu/entry.gd")
	var inst: Object = script.new()
	inst.call("on_load")
	_rule = RuleRegistry.default().resolve(&"o6")


func _ms(pairs: Array) -> Dictionary:
	var d := {}
	for p in pairs:
		d[Vector2i(int(p[0]), int(p[1]))] = true
	return d


func _val(mines: Array, pos: Vector2i, size: Vector2i) -> int:
	return int(_rule.call("compute_clue", _ms(mines), pos, size))


func test_registered_as_clue() -> void:
	assert_not_null(_rule, "o6 应已注册")
	assert_eq(str(_rule.call("get_kind")), "clue")


func test_empty_board_zero() -> void:
	assert_eq(_val([], Vector2i(2, 2), Vector2i(5, 5)), 0, "空盘 = 0")


func test_isolated_mine() -> void:
	# (2,1) 单雷（无邻雷）→ deg=0 → f(2,2)=0
	assert_eq(_val([[2, 1]], Vector2i(2, 2), Vector2i(5, 5)), 0, "孤立雷 deg=0 → 0")


func test_adjacent_pair() -> void:
	# (2,1) 与 (3,1) 相邻 → 对 (2,2) 而言：(2,1) 的 deg=1（邻 (3,1)）→ f=1
	assert_eq(_val([[2, 1], [3, 1]], Vector2i(2, 2), Vector2i(5, 5)), 1, "相邻雷对 → 1")


func test_cluster_heat() -> void:
	# 3 雷团：(2,1),(3,1),(3,2)——(3,1) 的 deg=2（邻 (2,1),(3,2)）→ f(2,2)=2
	assert_eq(_val([[2, 1], [3, 1], [3, 2]], Vector2i(2, 2), Vector2i(5, 5)), 2, "3 雷团 → 2")


func test_zero_diffused() -> void:
	# 热度 f=0 ⟺ 八邻无雷——可扩散（GDD §4.3）
	var zs: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(5, 5), 0)
	assert_gt(zs.size(), 0, "热度 0 值可扩散")
	var zn: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(5, 5), 3)
	assert_eq(zn.size(), 0, "非 0 不扩散")


func test_applies_to_all() -> void:
	assert_true(bool(_rule.call("applies_to", Vector2i(0, 0), Vector2i(5, 5))))
	assert_true(bool(_rule.call("applies_to", Vector2i(2, 2), Vector2i(5, 5))))


func test_upper_bound() -> void:
	assert_eq(int(_rule.call("value_upper_bound", Vector2i(5, 5))), 8)


func test_no_mask_support() -> void:
	assert_false(bool(_rule.call("supports_mask")), "本版不启用遮蔽")
