# test_o10_huanyou.gd —— O10「环游」单元测试（GUT）
# 覆盖：环序跳变计数 golden（角格/内部格/四段）、空环 0、全环 1、零值扩散契约、
# 值域与插件契约、与内置 loopruns 同语义对照。
extends GutTest

const MOD_DIR := "res://demo/mods/o10_huanyou"


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod(MOD_DIR)


func _rule() -> Object:
	return RuleRegistry.default().resolve(&"o10")


func _mines(cells: Array) -> Dictionary:
	var s := {}
	for c in cells:
		s[Vector2i(int(c[0]), int(c[1]))] = true
	return s


func test_corner_single_segment() -> void:
	# P=(0,0)（5×5）：环序（盘内格）=[(1,0)方位3,(1,1)方位4,(0,1)方位5]。
	# 仅 (1,0) 为雷：环 [1,0,0]（首尾相接），prev=(0,1)=0 → (1,0) 为段起点 → 1 段。
	var r: Object = _rule()
	var v: Variant = r.call("compute_clue", _mines([[1, 0]]), Vector2i(0, 0), Vector2i(5, 5))
	assert_eq(v, 1, "角格单雷 → 1 段")


func test_empty_ring_zero() -> void:
	# 空盘：环上无雷 → 0
	var r: Object = _rule()
	var v: Variant = r.call("compute_clue", {}, Vector2i(1, 1), Vector2i(5, 5))
	assert_eq(v, 0, "空环 → 0")


func test_full_ring_is_one() -> void:
	# P=(1,1) 八邻全雷：全环一段 → 1（含零值修复语义）
	var r: Object = _rule()
	var all8 := [[0, 0], [1, 0], [2, 0], [0, 1], [2, 1], [0, 2], [1, 2], [2, 2]]
	var v: Variant = r.call("compute_clue", _mines(all8), Vector2i(1, 1), Vector2i(5, 5))
	assert_eq(v, 1, "全雷环 → 视作一整段 = 1")


func test_four_segments_cross() -> void:
	# P=(2,2)（5×5）八邻十字四雷：(2,1)上、(3,2)右、(2,3)下、(1,2)左。
	# 环序（方位 1–8）：上雷、右上0、右雷、右下0、下雷、左下0、左雷、左上0 → 四个孤段 = 4。
	var r: Object = _rule()
	var v: Variant = r.call("compute_clue", _mines([[2, 1], [3, 2], [2, 3], [1, 2]]), Vector2i(2, 2), Vector2i(5, 5))
	assert_eq(v, 4, "十字四雷 → 4 段")


func test_two_segments_adjacent_pair() -> void:
	# P=(2,2)：方位1 (2,1) 与方位2 (3,1) 相邻两雷 → 合并 1 段；另加方位5 (2,3) → 共 2 段。
	var r: Object = _rule()
	var v: Variant = r.call("compute_clue", _mines([[2, 1], [3, 1], [2, 3]]), Vector2i(2, 2), Vector2i(5, 5))
	assert_eq(v, 2, "相邻两雷算一段 + 独立一雷 → 2 段")


func test_zero_value_contract() -> void:
	# 零值扩散契约：值 0 → 八邻域；值≠0 → 不扩散
	var r: Object = _rule()
	var n8: Array = r.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(5, 5), 0)
	assert_eq(n8.size(), 8, "值 0 → 八邻全量")
	assert_true(n8.has(Vector2i(1, 1)) and n8.has(Vector2i(3, 3)), "含对角邻格")
	var none: Array = r.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(5, 5), 2)
	assert_eq(none.size(), 0, "值≠0 不扩散")


func test_rule_contract() -> void:
	var r: Object = _rule()
	assert_eq(str(r.call("get_rule_id")), "o10", "rule id")
	assert_eq(str(r.call("get_kind")), "clue", "kind")
	assert_eq(int(r.call("value_upper_bound", Vector2i(9, 9))), 4, "值域上限 4")


func test_same_semantics_as_loopruns() -> void:
	# 与内置 loopruns 同语义对照（同 mine_set 同格，值必须一致）
	var r10: Object = _rule()
	var rlr: Object = RuleRegistry.default().resolve(&"loopruns")
	assert_not_null(rlr, "内置 loopruns 已注册")
	var cases := [
		{"m": [], "p": [1, 1]},
		{"m": [[2, 1], [3, 2], [2, 3], [1, 2]], "p": [2, 2]},
		{"m": [[2, 1], [3, 1], [2, 3], [1, 2], [1, 3]], "p": [2, 2]},
		{"m": [[0, 1], [1, 0]], "p": [0, 0]},
	]
	for c in cases:
		var ms := _mines(c["m"])
		var p := Vector2i(int(c["p"][0]), int(c["p"][1]))
		var v10: Variant = r10.call("compute_clue", ms, p, Vector2i(5, 5))
		var vlr: Variant = rlr.call("compute_clue", ms, p, Vector2i(5, 5))
		assert_eq(v10, vlr, "o10 与 loopruns 同值 @%s" % str(p))
