extends GutTest

## O7「奇显」算子测试（v3.0 S3）：golden 奇偶显示 + 契约（applies / 零扩散 / 值域）。
## 约定：「空」= -1。

var _rule: Object


func before_all() -> void:
	var script: Variant = load("res://demo/mods/o7_qixian/entry.gd")
	var inst: Object = script.new()
	inst.call("on_load")
	_rule = RuleRegistry.default().resolve(&"o7")


func _ms(pairs: Array) -> Dictionary:
	var d := {}
	for p in pairs:
		d[Vector2i(int(p[0]), int(p[1]))] = true
	return d


func _val(mines: Array, pos: Vector2i, size: Vector2i) -> int:
	return int(_rule.call("compute_clue", _ms(mines), pos, size))


func test_registered_as_clue() -> void:
	assert_not_null(_rule, "o7 应已注册")
	assert_eq(str(_rule.call("get_kind")), "clue")


func test_odd_even_display() -> void:
	var size := Vector2i(5, 5)
	var c := Vector2i(2, 2)
	var nbrs := [[1, 1], [2, 1], [3, 1], [1, 2], [3, 2], [1, 3], [2, 3], [3, 3]]
	assert_eq(_val([], c, size), -1, "0 雷（偶）→ 空")
	assert_eq(_val([nbrs[0]], c, size), 1, "1 雷（奇）→ 1")
	assert_eq(_val([nbrs[0], nbrs[1]], c, size), -1, "2 雷（偶）→ 空")
	assert_eq(_val([nbrs[0], nbrs[1], nbrs[2]], c, size), 3, "3 雷（奇）→ 3")
	assert_eq(_val(nbrs, c, size), -1, "8 雷（偶）→ 空")


func test_seven_mines_odd() -> void:
	var size := Vector2i(3, 3)
	var mines: Array = []
	for r in 3:
		for cc in 3:
			if not (r == 1 and cc == 1):
				mines.append([cc, r])
	mines.pop_back()   # 8 邻去掉 1 个 → 7 雷（奇）
	assert_eq(_val(mines, Vector2i(1, 1), size), 7, "7 雷（奇）→ 7")


func test_zero_not_diffused() -> void:
	var zs: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(5, 5), -1)
	assert_eq(zs.size(), 0, "奇显空值不可扩散")


func test_applies_to_all() -> void:
	assert_true(bool(_rule.call("applies_to", Vector2i(0, 0), Vector2i(5, 5))))
	assert_true(bool(_rule.call("applies_to", Vector2i(2, 2), Vector2i(5, 5))))


func test_upper_bound() -> void:
	assert_eq(int(_rule.call("value_upper_bound", Vector2i(5, 5))), 7)


func test_no_mask_support() -> void:
	assert_false(bool(_rule.call("supports_mask")), "奇显关不启用遮蔽（GDD 约定）")
