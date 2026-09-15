extends GutTest

## O8「钟点」算子测试（v3.0 S3）：golden 八方对照 + 角格绝对编号 + 契约。

var _rule: Object


func before_all() -> void:
	var script: Variant = load("res://demo/mods/o8_zhongdian/entry.gd")
	var inst: Object = script.new()
	inst.call("on_load")
	_rule = RuleRegistry.default().resolve(&"o8")


func test_registered_as_clue() -> void:
	assert_not_null(_rule, "o8 应已注册")
	assert_eq(str(_rule.call("get_kind")), "clue")


func test_golden_all_directions() -> void:
	# 内部格 (2,2)：八个方位各放一颗雷 → 编号 1..8；无雷 → 0
	var size := Vector2i(6, 6)
	var pos := Vector2i(2, 2)
	var dirs := [
		[Vector2i(0, -1), 1], [Vector2i(1, -1), 2], [Vector2i(1, 0), 3], [Vector2i(1, 1), 4],
		[Vector2i(0, 1), 5], [Vector2i(-1, 1), 6], [Vector2i(-1, 0), 7], [Vector2i(-1, -1), 8],
	]
	for d in dirs:
		var ms := {}
		ms[pos + (d[0] as Vector2i)] = true
		assert_eq(int(_rule.call("compute_clue", ms, pos, size)), int(d[1]),
			"方位 %s → 编号 %d" % [str(d[0]), int(d[1])])
	var empty := {}
	assert_eq(int(_rule.call("compute_clue", empty, pos, size)), 0, "无雷 → 0")


func test_first_mine_wins() -> void:
	# 多雷时取「扫描顺序最前」：右上(2) + 上(1) 都有 → 1；右(3) + 右上(2) → 2
	var size := Vector2i(6, 6)
	var pos := Vector2i(2, 2)
	var ms := {}
	ms[Vector2i(3, 1)] = true   # 右上 (2)
	ms[Vector2i(2, 1)] = true   # 上 (1)
	assert_eq(int(_rule.call("compute_clue", ms, pos, size)), 1, "上 优先于 右上")
	ms = {}
	ms[Vector2i(3, 2)] = true   # 右 (3)
	ms[Vector2i(3, 1)] = true   # 右上 (2)
	assert_eq(int(_rule.call("compute_clue", ms, pos, size)), 2, "右上 优先于 右")


func test_corner_absolute_numbering() -> void:
	# 右上角 (5,0)（6×6）：越界方位跳过但保留绝对编号。
	# 可见方位及编号：下(5)、左下(6)、左(7)。扫描序 5→6→7。
	var size := Vector2i(6, 6)
	var pos := Vector2i(5, 0)
	var ms := {}
	ms[Vector2i(4, 1)] = true    # 左下 → 6
	assert_eq(int(_rule.call("compute_clue", ms, pos, size)), 6, "角格：左下 → 6（绝对编号）")
	ms = {}
	ms[Vector2i(5, 1)] = true    # 下 → 5
	assert_eq(int(_rule.call("compute_clue", ms, pos, size)), 5, "角格：下 → 5")
	ms = {}
	ms[Vector2i(4, 0)] = true    # 左 → 7
	assert_eq(int(_rule.call("compute_clue", ms, pos, size)), 7, "角格：左 → 7")
	ms = {}
	ms[Vector2i(4, 0)] = true    # 左 (7)
	ms[Vector2i(5, 1)] = true    # 下 (5)
	assert_eq(int(_rule.call("compute_clue", ms, pos, size)), 5, "角格：下 优先于 左")


func test_zero_safe_neighbors() -> void:
	var zs: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(6, 6), 0)
	assert_eq(zs.size(), 8, "内部格 0 值 → 八邻可扩散")
	var zc: Array = _rule.call("zero_safe_neighbors", Vector2i(5, 0), Vector2i(6, 6), 0)
	assert_eq(zc.size(), 3, "角格 0 值 → 盘内三邻可扩散")
	var zn: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(6, 6), 5)
	assert_eq(zn.size(), 0, "非 0 不扩散")


func test_bounds_and_mask() -> void:
	assert_eq(int(_rule.call("value_upper_bound", Vector2i(6, 6))), 8, "值域上限 8")
	assert_false(bool(_rule.call("supports_mask")), "不参与遮蔽（GDD §4.4）")
	assert_true(bool(_rule.call("applies_to", Vector2i(0, 0), Vector2i(5, 5))), "全格铺线索")


func test_generated_consistency() -> void:
	# 生成一关：逐格手工重算（独立实现）对照 compute_clue
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var mines: Array = _rule.call("place_mines", rng, 6, 6, 14)
	assert_eq(mines.size(), 14, "布雷 14")
	var ms := {}
	for p in mines:
		ms[p] = true
	var ring := [
		Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
		Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1),
	]
	for r in 6:
		for c in 6:
			var pos := Vector2i(c, r)
			if ms.has(pos):
				continue
			var expect := 0
			for i in ring.size():
				var q: Vector2i = pos + ring[i]
				if q.x < 0 or q.x >= 6 or q.y < 0 or q.y >= 6:
					continue
				if ms.has(q):
					expect = i + 1
					break
			var f := int(_rule.call("compute_clue", ms, pos, Vector2i(6, 6)))
			assert_eq(f, expect, "格 (%d,%d) 手工重算一致" % [c, r])
