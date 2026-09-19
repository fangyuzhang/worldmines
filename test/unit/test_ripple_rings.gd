# test_ripple_rings.gd —— RippleRings（开格波浪按图距离分环）单元测试
#
# 用 preload 而非全局类名，避免新增脚本的全局类缓存尚未刷新时测试无法解析。
extends GutTest

const Ripple := preload("res://core/ripple_rings.gd")


## 8 邻接（本项目棋盘用 8 邻）。**刻意不做边界过滤**：调用方的邻接表未必干净，
## 正好用来验证模块自身会剔除越界/重复项。
func _neighbors_8(pos: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			out.append(Vector2i(pos.x + dx, pos.y + dy))
	return out


func _call_n8() -> Callable:
	return Callable(self, "_neighbors_8")


# ---------- 分环正确性 ----------

## 5×5、8 邻、从中心 (2,2)：第 0 环=起点本身，第 1 环=紧邻 8 格（不含起点），
## 第 2 环=剩余 16 格，到角落距离 2 → 共 3 环。
func test_5x5_center_rings() -> void:
	var rings: Array = Ripple.build(Vector2i(2, 2), Vector2i(5, 5), _call_n8())

	assert_eq(rings.size(), 3, "5×5 中心出发应有 3 环（环 0 + 环 1 + 环 2）")
	assert_eq(rings[0].size(), 1, "环 0 只含起点自身")
	assert_eq(rings[0][0], Vector2i(2, 2), "环 0 应是起点")
	assert_eq(rings[1].size(), 8, "中心出发的第 1 环应是 8 邻")
	assert_false(rings[1].has(Vector2i(2, 2)), "第 1 环不得含起点")
	assert_eq(rings[2].size(), 16, "第 2 环应覆盖剩余 16 格")

	_assert_in_bounds(rings, Vector2i(5, 5))
	_assert_covers_all_once(rings, Vector2i(5, 5))


## 5×5 从角落 (0,0)：环大小 1/3/5/7/9，共 5 环，恰好覆盖全盘。
func test_5x5_corner_rings_grow_until_full() -> void:
	var rings: Array = Ripple.build(Vector2i(0, 0), Vector2i(5, 5), _call_n8())
	var expected := [1, 3, 5, 7, 9]

	assert_eq(rings.size(), expected.size(), "5×5 角落出发应恰好 5 环")
	for i in expected.size():
		assert_eq(rings[i].size(), expected[i], "第 %d 环大小应为 %d" % [i, expected[i]])
	assert_eq(rings[1].size(), 3, "角落第 1 环应只有 3 格")

	_assert_in_bounds(rings, Vector2i(5, 5))
	_assert_covers_all_once(rings, Vector2i(5, 5))


## 非正方形棋盘（3 列 × 5 行）也要按 size 正确裁边并覆盖全盘。
func test_rectangular_board() -> void:
	var size := Vector2i(3, 5)
	var rings: Array = Ripple.build(Vector2i(0, 0), size, _call_n8())
	var expected := [1, 3, 5, 3, 3]

	assert_eq(rings.size(), expected.size(), "3×5 角落出发应有 5 环")
	for i in expected.size():
		assert_eq(rings[i].size(), expected[i], "第 %d 环大小应为 %d" % [i, expected[i]])

	_assert_in_bounds(rings, size)
	_assert_covers_all_once(rings, size)


# ---------- 边界与健壮性 ----------

## 起点贴边（含四角）不产生越界坐标。
func test_edge_starts_stay_in_bounds() -> void:
	var size := Vector2i(5, 5)
	for start in [Vector2i(0, 0), Vector2i(4, 0), Vector2i(0, 4), Vector2i(4, 4),
			Vector2i(0, 2), Vector2i(2, 4)]:
		var rings: Array = Ripple.build(start, size, _call_n8())
		assert_eq(rings[0][0], start, "环 0 应是起点 %s" % start)
		_assert_in_bounds(rings, size)
	_assert_covers_all_once(Ripple.build(Vector2i(0, 0), size, _call_n8()), size)


## 邻接表返回重复项与越界坐标时，模块应自行去重/剔除。
func test_bad_neighbors_filtered() -> void:
	var bad := func(pos: Vector2i) -> Array:
		var out: Array = []
		out.append(pos + Vector2i(1, 0))
		out.append(pos + Vector2i(1, 0))     # 重复
		out.append(Vector2i(-3, -7))         # 越界
		return out
	var rings: Array = Ripple.build(Vector2i(0, 0), Vector2i(3, 3), bad)

	# 只能沿 +x 推进：(0,0) → (1,0) → (2,0) → 结束
	assert_eq(rings.size(), 3, "重复/越界项应被过滤，只剩 3 环")
	assert_eq(rings[1], [Vector2i(1, 0)], "重复邻居只记一次")
	assert_eq(rings[2], [Vector2i(2, 0)], "越界邻居被剔除")
	_assert_in_bounds(rings, Vector2i(3, 3))
	assert_eq(_assert_no_duplicates(rings), 3, "去重后应恰好 3 格，无重复计数")


## 起点越界 / 尺寸非正 → 空数组（不崩溃、不臆造）。
func test_invalid_input_returns_empty() -> void:
	assert_eq(Ripple.build(Vector2i(-1, 0), Vector2i(5, 5), _call_n8()), [],
		"起点 x 越界应返回空数组")
	assert_eq(Ripple.build(Vector2i(5, 0), Vector2i(5, 5), _call_n8()), [],
		"起点 x 越界（右）应返回空数组")
	assert_eq(Ripple.build(Vector2i(0, 5), Vector2i(5, 5), _call_n8()), [],
		"起点 y 越界应返回空数组")
	assert_eq(Ripple.build(Vector2i(0, 0), Vector2i(0, 0), _call_n8()), [],
		"尺寸非正应返回空数组")


## max_rings 是扩散安全上限（防环形拓扑无限扩散）。
func test_max_rings_cap() -> void:
	var size := Vector2i(5, 5)
	assert_eq(Ripple.build(Vector2i(2, 2), size, _call_n8(), 0).size(), 1,
		"max_rings=0 只返回环 0")
	var one: Array = Ripple.build(Vector2i(2, 2), size, _call_n8(), 1)
	assert_eq(one.size(), 2, "max_rings=1 只返回环 0 与环 1")
	assert_eq(one[1].size(), 8, "被截断时环 1 仍完整")
	assert_eq(Ripple.total_rings(one), 2, "total_rings 应等于环数组长度")


# ---------- 时间模型 ----------

## delay(0)=0、delay(1)=0（环 0/1 同时，刻意设计）、delay(d)=(d-1)*ws。
func test_delay_model() -> void:
	var ws := 0.25
	assert_almost_eq(Ripple.delay_of(0, ws), 0.0, 0.000001, "环 0 应无延迟")
	assert_almost_eq(Ripple.delay_of(1, ws), 0.0, 0.000001, "环 1 应与环 0 同时开始（刻意）")
	assert_almost_eq(Ripple.delay_of(2, ws), ws, 0.000001, "环 2 延迟应为 1*ws")
	assert_almost_eq(Ripple.delay_of(3, ws), 2.0 * ws, 0.000001, "环 3 延迟应为 2*ws")
	assert_almost_eq(Ripple.delay_of(10, ws), 9.0 * ws, 0.000001, "通用式 (d-1)*ws")
	assert_almost_eq(Ripple.delay_of(-1, ws), 0.0, 0.000001, "负环按 <=1 处理为 0")


func test_total_rings() -> void:
	assert_eq(Ripple.total_rings([]), 0, "空数组 0 环")
	var rings: Array = Ripple.build(Vector2i(2, 2), Vector2i(5, 5), _call_n8())
	assert_eq(Ripple.total_rings(rings), 3, "中心出发 3 环")


# ---------- 断言工具 ----------

## 无重复：每格最多出现一次；返回环内出现的总格数。
func _assert_no_duplicates(rings: Array) -> int:
	var seen: Dictionary = {}
	var total := 0
	for ring in rings:
		for p in ring:
			var q: Vector2i = p
			assert_false(seen.has(q), "格 %s 出现在多个环（有重复）" % q)
			seen[q] = true
			total += 1
	return total


## 最重要的不变量：所有环拼起来恰好等于全盘每格一次（无重复、无遗漏）。
func _assert_covers_all_once(rings: Array, size: Vector2i) -> void:
	var total := _assert_no_duplicates(rings)
	assert_eq(total, size.x * size.y, "环内总格数应等于全盘格数（无遗漏）")


func _assert_in_bounds(rings: Array, size: Vector2i) -> void:
	for ring in rings:
		for p in ring:
			var q: Vector2i = p
			assert_true(q.x >= 0 and q.x < size.x and q.y >= 0 and q.y < size.y,
				"环内出现越界坐标 %s（棋盘 %s）" % [q, size])
