extends GutTest

## 形状布尔运算（格集并/交/差/异或）契约测试。
##
## 钉住的不变量（坏一条，用户要么拿到错结果、要么拿到"顺序每次都不一样"的不可复现结果）：
##   1) 四种运算在 不相交 / 包含 / 相同 三类边界上结果正确；
##   2) 输出按 (y, x) 升序排序，两次调用逐项相同（可复现）；
##   3) `apply_to_grid` 借助 `in_board()` 丢弃盘外格并返回清单，**异形盘不按包围盒放行幽灵格**；
##   4) 输入超过 `MAX_CELL_BUDGET` 被拒且给可读原因；
##   5) 性能守卫：两个 5000 格集合的并/交在毫秒级预算内完成。


# ==================== 1. 四种运算正确性（含三类边界） ====================

func test_union_disjoint_contained_identical() -> void:
	# 不相交
	var r1 := ShapeBoolean.union(_cells([0, 0, 1, 0]), _cells([5, 5]))
	assert_true(bool(r1["ok"]))
	assert_eq(r1["cells"], _cells([0, 0, 1, 0, 5, 5]), "不相交并集 = 两者之和")
	# 包含：b ⊂ a ⇒ a ∪ b = a（顺序仍规范化）
	var r2 := ShapeBoolean.union(_cells([0, 0, 1, 0, 2, 0]), _cells([1, 0]))
	assert_eq(r2["cells"], _cells([0, 0, 1, 0, 2, 0]), "包含关系下并集 = 超集")
	# 完全相同
	var r3 := ShapeBoolean.union(_cells([1, 0, 0, 1]), _cells([1, 0, 0, 1]))
	assert_eq(r3["cells"], _cells([1, 0, 0, 1]), "相同集合并集 = 自身")


func test_intersect_disjoint_contained_identical() -> void:
	var disjoint := ShapeBoolean.intersect(_cells([0, 0]), _cells([5, 5]))
	assert_true(bool(disjoint["ok"]))
	assert_eq(disjoint["count"], 0, "不相交交集为空")
	var contained := ShapeBoolean.intersect(_cells([0, 0, 1, 0, 2, 0]), _cells([1, 0]))
	assert_eq(contained["cells"], _cells([1, 0]), "包含关系下交集 = 子集")
	var same := ShapeBoolean.intersect(_cells([3, 1, 2, 2]), _cells([3, 1, 2, 2]))
	assert_eq(same["cells"], _cells([3, 1, 2, 2]), "相同集合并集 = 自身")


func test_difference_disjoint_contained_identical() -> void:
	var disjoint := ShapeBoolean.difference(_cells([0, 0]), _cells([5, 5]))
	assert_eq(disjoint["cells"], _cells([0, 0]), "与不相交集做差 = 原集")
	var contained := ShapeBoolean.difference(_cells([0, 0, 1, 0, 2, 0]), _cells([1, 0]))
	assert_eq(contained["cells"], _cells([0, 0, 2, 0]), "减去子集 = 去掉那些格")
	var same := ShapeBoolean.difference(_cells([0, 0, 1, 1]), _cells([0, 0, 1, 1]))
	assert_eq(same["count"], 0, "自身减自身为空")
	# 非交换：被减集不同，结果不同
	var rev := ShapeBoolean.difference(_cells([1, 0]), _cells([1, 0, 9, 9]))
	assert_eq(rev["count"], 0, "子集减超集为空")
	assert_eq(ShapeBoolean.difference(_cells([1, 0, 9, 9]), _cells([1, 0]))["cells"],
		_cells([9, 9]), "超集减子集保留差")


func test_xor_disjoint_contained_identical() -> void:
	var disjoint := ShapeBoolean.xor(_cells([0, 0]), _cells([5, 5]))
	assert_eq(disjoint["cells"], _cells([0, 0, 5, 5]), "不相交异或 = 并集")
	var contained := ShapeBoolean.xor(_cells([0, 0, 1, 0, 2, 0]), _cells([1, 0]))
	assert_eq(contained["cells"], _cells([0, 0, 2, 0]), "包含关系下异或 = 差集")
	var same := ShapeBoolean.xor(_cells([2, 3, 4, 5]), _cells([2, 3, 4, 5]))
	assert_eq(same["count"], 0, "相同集合异或为空")


# ==================== 2. 空集 / 单集 / 相同集合边界 ====================

func test_empty_and_singleton_edges() -> void:
	assert_eq(int(ShapeBoolean.union([], [])["count"]), 0, "空 ∪ 空 = 空")
	assert_eq(int(ShapeBoolean.intersect(_cells([0, 0]), [])["count"]), 0, "与空集相交 = 空")
	assert_eq(ShapeBoolean.difference(_cells([0, 0]), [])["cells"], _cells([0, 0]), "减空集 = 原集")
	assert_eq(ShapeBoolean.difference([], _cells([0, 0]))["cells"], [] as Array[Vector2i], "空集减任何 = 空")
	assert_eq(ShapeBoolean.xor(_cells([7, 7]), [])["cells"], _cells([7, 7]), "与空集异或 = 原集")
	# 任何运算与空集的结果都必须 ok（空集是合法输入，不是错误）
	assert_true(bool(ShapeBoolean.intersect([], [])["ok"]), "空集运算不得被当成错误")


# ==================== 3. 输出稳定排序（可复现） ====================

func test_output_sorted_and_reproducible() -> void:
	# 故意乱序输入：输出必须按 (y, x) 升序
	var a := _cells([0, 1, 2, 0, 1, 0, 0, 0])   # (x,y) = (0,1)(2,0)(1,0)(0,0)
	var r := ShapeBoolean.union(a, [])
	assert_eq(r["cells"], _cells([0, 0, 1, 0, 2, 0, 0, 1]), "输出须按 (y,x) 升序")
	# 同一输入两次调用逐项相同（字典遍历顺序不作数）
	var r1 := ShapeBoolean.xor(_cells([1, 1, 0, 0, 2, 2]), _cells([0, 0, 9, 9]))
	var r2 := ShapeBoolean.xor(_cells([1, 1, 0, 0, 2, 2]), _cells([0, 0, 9, 9]))
	assert_eq(r1["cells"], r2["cells"], "两次调用结果必须逐项相同")
	assert_eq(r1["cells"], _cells([1, 1, 2, 2, 9, 9]), "异或结果也已排序")


func test_input_accepts_array_and_dictionary() -> void:
	var as_array := ShapeBoolean.union(_cells([0, 0]), _cells([1, 1]))
	var as_dict := ShapeBoolean.union(
		{Vector2i(0, 0): true}, [{"x": 1, "y": 1}])   # {x,y} 是 Array 的元素写法
	assert_eq(as_dict["cells"], as_array["cells"], "Array / Dictionary / {x,y} 三种写法同口径")
	assert_eq(ShapeBoolean.intersect({Vector2i(2, 2): null}, _cells([2, 2]))["count"], 1,
		"字典的值被忽略，只看键")


func test_malformed_input_rejected_readably() -> void:
	var bad := ShapeBoolean.union([1, 2], [])
	assert_false(bool(bad["ok"]), "非法元素必须被拒（不静默）")
	assert_true(str(bad["reason"]).find("无法解析") != -1, "原因要可读：%s" % str(bad["reason"]))
	assert_false(bool(ShapeBoolean.union(null, [])["ok"]), "null 不是空集，应被拒")


# ==================== 4. apply_to_grid：盘外格丢弃 + 清单 ====================

func test_apply_to_grid_discards_out_of_board_with_list() -> void:
	var grid := RectGrid.new()
	grid.setup(2, 2)   # 盘内仅 (0,0)(1,0)(0,1)(1,1)
	var res := ShapeBoolean.apply_to_grid(_cells([0, 0, 1, 1, 5, 5, 255, 0]), grid)
	assert_true(bool(res["ok"]))
	assert_eq(res["cells"], _cells([0, 0, 1, 1]), "只保留盘内格")
	assert_eq(res["discarded"], _cells([255, 0, 5, 5]), "盘外格进丢弃清单且按 (y,x) 升序")
	assert_eq(int(res["count"]), 2)
	assert_true(str(res["reason"]).find("2 格不在盘内") != -1, "原因要写清丢弃数：%s" % str(res["reason"]))


func test_apply_to_grid_all_inside_has_empty_discard() -> void:
	var grid := RectGrid.new()
	grid.setup(3, 3)
	var res := ShapeBoolean.apply_to_grid(_cells([0, 0, 2, 2]), grid)
	assert_true(bool(res["ok"]))
	assert_eq(int(res["count"]), 2)
	assert_eq(res["discarded"].size(), 0, "全在盘内时丢弃清单为空")
	assert_eq(str(res["reason"]), "", "全在盘内时无提示文案")


func test_apply_to_grid_sparse_uses_in_board_not_bbox() -> void:
	# 异形/稀疏盘：盘上只有 (0,0) 与 (3,3)；(1,1) 落在包围盒内但**不在盘上** —— 必须被丢弃。
	var sparse := SparseGrid.new(_cells([0, 0, 3, 3]))
	assert_eq(sparse.all_positions().size(), 2)
	var res := ShapeBoolean.apply_to_grid(_cells([0, 0, 1, 1, 3, 3]), sparse)
	assert_eq(res["cells"], _cells([0, 0, 3, 3]), "只按 in_board() 判定，不按包围盒")
	assert_eq(res["discarded"], _cells([1, 1]), "包围盒内的空位也是盘外格")


# ==================== 5. 规模上限：拒绝 + 可读原因 ====================

func test_over_budget_rejected_with_reason() -> void:
	var huge: Array[Vector2i] = []
	for i in ShapeBoolean.MAX_CELL_BUDGET + 1:
		huge.append(Vector2i(i, 0))
	var res := ShapeBoolean.union(huge, [])
	assert_false(bool(res["ok"]), "超上限必须拒绝")
	assert_eq(int(res["count"]), 0, "拒绝时不产出结果")
	assert_eq(res["cells"].size(), 0)
	assert_true(str(res["reason"]).find(str(ShapeBoolean.MAX_CELL_BUDGET)) != -1,
		"原因里要写明上限 %d：%s" % [ShapeBoolean.MAX_CELL_BUDGET, str(res["reason"])])
	# 恰好等于上限 ⇒ 允许（门槛是 > 上限）
	var at_limit: Array[Vector2i] = []
	for i in ShapeBoolean.MAX_CELL_BUDGET:
		at_limit.append(Vector2i(i, 0))
	assert_true(bool(ShapeBoolean.union(at_limit, [])["ok"]), "恰好 5000 格应被允许")
	# apply_to_grid 同样受上限约束
	var grid := RectGrid.new()
	grid.setup(9, 9)
	assert_false(bool(ShapeBoolean.apply_to_grid(huge, grid)["ok"]), "apply_to_grid 也须硬阻")


# ==================== 6. 性能守卫（格集布尔是 O(n+m)） ====================

func test_performance_guard_two_5000_sets() -> void:
	# 文档警告"顶点两两求交 O(N×M)"：本实现无顶点、无配对，应随规模线性。
	# 造两个各 5000 格、半重叠的集合（并集上限 7500，交集 2500）。
	var a: Array[Vector2i] = []
	var b: Array[Vector2i] = []
	for i in ShapeBoolean.MAX_CELL_BUDGET:
		a.append(Vector2i(i, 0))
		b.append(Vector2i(i + 2500, 0))
	var t0 := Time.get_ticks_msec()
	var u := ShapeBoolean.union(a, b)
	var inter := ShapeBoolean.intersect(a, b)
	var dt := Time.get_ticks_msec() - t0
	assert_true(bool(u["ok"]) and bool(inter["ok"]), "5000 格级输入应在允许范围内")
	assert_eq(int(u["count"]), 7500, "并集应含 7500 格")
	assert_eq(int(inter["count"]), 2500, "交集应含 2500 格")
	# 阈值依据：格集布尔实测为个位数毫秒；CI 用 10 分片并行跑、机器负载会抖，
	# 故取 500 ms（≈100 倍余量）——宽到不会因负载随机红，仍能把"退化成 O(N×M) 配对"的实现拦下
	# （若真按顶点两两判定，2500 万级比较在 GDScript 里远超 500 ms）。
	assert_true(dt < 500, "两个 5000 格集合的并/交应在 500 ms 内完成（实测 %d ms）" % dt)


# ==================== 测试辅助 ====================

## 把扁平的 [x, y, x, y, ...] 展开成格坐标数组（测试写法更短，且顺序刻意不排序）。
func _cells(flat: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var i := 0
	while i + 1 < flat.size():
		out.append(Vector2i(int(flat[i]), int(flat[i + 1])))
		i += 2
	return out


## 稀疏盘替身：in_board = 成员集（与 AdjacencyGrid 同口径，包围盒 4×4 但只存在 2 格）。
class SparseGrid extends GridInterface:
	var _set := {}
	func _init(cells: Array) -> void:
		for c in cells:
			_set[c] = true
	func in_board(pos: Vector2i) -> bool:
		return _set.has(pos)
	func all_positions() -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		for k in _set:
			out.append(k)
		return out
	func size() -> Vector2i:
		return Vector2i(4, 4)
	func cell_count() -> int:
		return _set.size()
