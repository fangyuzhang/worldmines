extends GutTest

## 形状间空隙的「填充」（功能清单 §3「填充系统」：实心 / 环形 / 图案）契约测试。
##
## 钉住的不变量（坏一条，用户要么拿到错形状、要么手工修改被静默覆盖）：
##   1) 三种样式各自结果正确：实心 = 全填 / 环形 = 只留边缘一圈 / 图案 = 单元平铺且只在空隙内；
##   2) 手工改过的格**绝不进结果**，且一定列进 protected + 给出可读 reason（不许静默忽略）；
##   3) 超过 MAX_CELL_BUDGET / 非法输入 → ok=false + 可读原因（不静默吞）；
##   4) 输出按 (y, x) 升序、两次调用逐项相同（可复现）；
##   5) count 恒等于 cells.size()（守恒）。

const FILL := preload("res://core/shape_fill.gd")


func test_solid_fills_every_region_cell() -> void:
	var r := FILL.fill(_cells([0, 0, 1, 0, 0, 1]), {"mode": FILL.MODE_SOLID})
	assert_true(bool(r["ok"]), "实心填充应成功")
	assert_eq(r["cells"], _cells([0, 0, 1, 0, 0, 1]), "实心 = 空隙本体，且按 (y, x) 升序")
	assert_eq(int(r["count"]), 3, "count 应等于 3")
	assert_true((r["protected"] as Array).is_empty(), "没有手工格 ⇒ 没有被保护的格")
	assert_eq(str(r["reason"]), "", "没有要跳过的格 ⇒ 理由为空")


func test_ring_keeps_only_the_boundary_ring() -> void:
	var full: Array[Vector2i] = []
	for y in 3:
		for x in 3:
			full.append(Vector2i(x, y))
	var r := FILL.fill(full, {"mode": FILL.MODE_RING})
	assert_true(bool(r["ok"]), "环形填充应成功")
	assert_eq(int(r["count"]), 8, "3×3 实心块的边缘一圈 = 8 格")
	assert_false((r["cells"] as Array).has(Vector2i(1, 1)), "内芯不填（留出走得通的通道）")
	var one := FILL.fill([Vector2i(4, 4)], {"mode": FILL.MODE_RING})
	assert_eq(int(one["count"]), 1, "单格空隙：它自己就是边缘，整格留下")


func test_pattern_tiles_the_unit_and_clips_to_region() -> void:
	var region: Array[Vector2i] = []
	for y in 4:
		for x in 4:
			region.append(Vector2i(x, y))
	# 单元 = 2×2 里的一条对角线 ☑(0,0) + ☑(1,1)；原点默认 = 空隙左上角
	var diag_unit := [Vector2i(0, 0), Vector2i(1, 1)]
	var diag := FILL.fill(region, {"mode": FILL.MODE_PATTERN, "unit": diag_unit})
	assert_true(bool(diag["ok"]), "图案填充应成功")
	assert_eq(int(diag["count"]), 8, "4×4 上 2×2 对角线单元应落 8 格")
	assert_true((diag["cells"] as Array).has(Vector2i(0, 0)), "原点格必落")
	assert_false((diag["cells"] as Array).has(Vector2i(1, 0)), "单元里没有的相位不落")
	# 平移原点会整体挪动落点（同一条单元、不同的平铺相位）
	var shifted := FILL.fill(region, {"mode": FILL.MODE_PATTERN, "unit": diag_unit,
		"anchor": Vector2i(1, 0)})
	assert_true((shifted["cells"] as Array).has(Vector2i(1, 0)), "原点 (1,0) 时该格应落")
	assert_false((shifted["cells"] as Array).has(Vector2i(0, 0)), "原点移动后旧原点格不再落")
	# 只在空隙内落：空隙缺的格**不许**被图案补回来
	var holed: Array[Vector2i] = []
	for p in region:
		if p != Vector2i(0, 0):
			holed.append(p)
	var clipped := FILL.fill(holed, {"mode": FILL.MODE_PATTERN, "unit": diag_unit})
	assert_eq(int(clipped["count"]), 7, "图案只在空隙内落格（空隙缺的格不许被补）")
	assert_false((clipped["cells"] as Array).has(Vector2i(0, 0)), "空格不许被图案补回来")


func test_hand_edited_cells_are_never_overwritten() -> void:
	var region := _cells([0, 0, 1, 0, 2, 0])
	var r := FILL.fill(region, {"mode": FILL.MODE_SOLID, "hand_edited": _cells([1, 0])})
	assert_true(bool(r["ok"]), "带手工格的填充应成功（跳过而不是报错）")
	assert_eq(r["cells"], _cells([0, 0, 2, 0]), "手工改过的格不进结果（下次填充不得覆盖）")
	assert_eq(r["protected"], _cells([1, 0]), "被跳过的格必须原样列进 protected")
	assert_ne(str(r["reason"]), "", "跳过必须说出来（不许静默忽略）")
	assert_true(str(r["reason"]).contains("手工"), "理由要读得懂（实际：%s）" % str(r["reason"]))
	# 手工格不在空隙里 ⇒ 不产生多余的 protected / reason
	var none := FILL.fill(region, {"mode": FILL.MODE_SOLID, "hand_edited": _cells([9, 9])})
	assert_true((none["protected"] as Array).is_empty(), "无关的手工格不该出现在 protected 里")
	assert_eq(str(none["reason"]), "", "没有真的跳过任何格 ⇒ 理由为空")


func test_bad_input_and_budget_are_rejected_with_readable_reason() -> void:
	assert_false(bool(FILL.fill(null)["ok"]), "null 空隙应被拒（空集请传 []）")
	assert_false(bool(FILL.fill("nope")["ok"]), "不支持的容器类型应被拒")
	assert_false(bool(FILL.fill([], {"mode": "spiral"})["ok"]),
		"未知样式应被拒，不得静默按实心处理")
	assert_false(bool(FILL.fill([], {"mode": FILL.MODE_PATTERN})["ok"]), "图案样式缺 unit 应被拒")
	assert_false(bool(FILL.fill([], {"mode": FILL.MODE_PATTERN, "unit": []})["ok"]),
		"空图案单元应被拒")
	var big: Array[Vector2i] = []
	for i in (FILL.MAX_CELL_BUDGET + 1):
		big.append(Vector2i(i, 0))
	var over := FILL.fill(big)
	assert_false(bool(over["ok"]), "超过 MAX_CELL_BUDGET 应被拒（事前硬阻）")
	assert_true(str(over["reason"]).contains(str(FILL.MAX_CELL_BUDGET)),
		"理由要说出上限（实际：%s）" % str(over["reason"]))
	assert_eq(int(over["count"]), 0, "被拒的结果必须为空")
	assert_true((over["cells"] as Array).is_empty(), "被拒的结果必须为空")


func test_output_is_sorted_and_reproducible() -> void:
	var region := _cells([3, 3, 0, 0, 2, 1, 1, 2, 0, 3])
	var a := FILL.fill(region, {"mode": FILL.MODE_SOLID})
	var b := FILL.fill(region, {"mode": FILL.MODE_SOLID})
	assert_eq(a["cells"], b["cells"], "两次同输入必须逐项相同（字典遍历顺序不作数）")
	var got: Array = (a["cells"] as Array).duplicate()
	var want: Array = (a["cells"] as Array).duplicate()
	want.sort_custom(func(p: Vector2i, q: Vector2i) -> bool:
		if p.y != q.y:
			return p.y < q.y
		return p.x < q.x)
	assert_eq(got, want, "输出必须已按 (y, x) 升序")
	assert_eq(int(a["count"]), (a["cells"] as Array).size(), "count 必须等于 cells.size()（守恒）")
	var empty := FILL.fill([])
	assert_true(bool(empty["ok"]), "空空隙是合法输入（不是错误）")
	assert_eq(int(empty["count"]), 0, "空空隙填出 0 格")


func test_describe_reads_like_a_sentence() -> void:
	var r := FILL.fill(_cells([0, 0, 1, 0]),
		{"mode": FILL.MODE_SOLID, "hand_edited": _cells([1, 0])})
	assert_true(FILL.describe(r).contains("1"), "文案要带数字（实际：%s）" % FILL.describe(r))
	assert_true(FILL.describe(r).contains("跳过"), "跳过了手工格就要说出来（实际：%s）" % FILL.describe(r))
	assert_true(FILL.describe(FILL.fill(null)).begins_with("填充失败"), "失败也要给出可读文案")


# ==================== 测试辅助 ====================

## 把扁平的 [x, y, x, y, ...] 展开成格坐标数组（写法更短，且顺序刻意不排序）。
func _cells(flat: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var i := 0
	while i + 1 < flat.size():
		out.append(Vector2i(int(flat[i]), int(flat[i + 1])))
		i += 2
	return out
