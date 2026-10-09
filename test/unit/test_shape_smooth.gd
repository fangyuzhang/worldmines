extends GutTest

## 边缘平滑（腐蚀 / 膨胀）的「连通性硬校验」契约测试（功能清单 §3「边缘平滑」硬约束）。
##
## 钉住的不变量（坏一条，用户就会拿到"看着没事、逻辑上整个迷宫已经变了"的盘）：
##   1) 正常腐蚀 / 膨胀：格集与补集的连通分量数都**不变**才放行，结果正确；
##   2) 「细梁弄断」= 格集分量变多 ⇒ **拒绝**，分类 beam_cut，problem = 被挖掉的断点；
##   3) 「缝隙填死」= 补集分量变少 ⇒ **拒绝**，分类 void_merged，problem = 新填的塞子；
##   4) 手工格**保持原状**并进 protected + 可读 reason；保护也救不回来的场合照样拒绝；
##   5) 未知模式 / 空盘 / 超预算 → ok=false + 可读原因；输出按 (y, x) 升序且可复现。

const SMOOTH := preload("res://core/shape_smooth.gd")


func test_erode_shrinks_a_solid_block_without_touching_connectivity() -> void:
	var g := _rect(7, 7)
	var r := SMOOTH.apply(_block(1, 1, 5, 5), g, SMOOTH.MODE_ERODE)
	assert_true(bool(r["ok"]), "5×5 实心块内缩一圈不破坏连通性，应放行（实际：%s）" % str(r["reason"]))
	assert_eq(int(r["count"]), 9, "5×5 内缩一圈 = 3×3 = 9 格")
	assert_eq(int(r["before"]["regions"]), 1, "执行前格集 = 1 块")
	assert_eq(int(r["after"]["regions"]), 1, "执行后仍 = 1 块")
	assert_eq(int(r["before"]["void_regions"]), int(r["after"]["void_regions"]), "空隙块数必须不变")
	assert_eq((r["added"] as Array).size(), 0, "腐蚀只会挖，不会补")
	assert_eq((r["removed"] as Array).size(), 16, "25 − 9 = 16 格被挖掉")
	assert_eq(str(r["problem_kind"]), "", "放行的结果不该有问题分类")


func test_dilate_grows_a_solid_block_without_touching_connectivity() -> void:
	var g := _rect(7, 7)
	var r := SMOOTH.apply(_block(2, 2, 3, 3), g, SMOOTH.MODE_DILATE)
	assert_true(bool(r["ok"]), "3×3 外扩一圈不破坏连通性，应放行（实际：%s）" % str(r["reason"]))
	assert_eq(int(r["count"]), 25, "3×3 外扩一圈 = 5×5 = 25 格")
	assert_eq((r["removed"] as Array).size(), 0, "膨胀只会补，不会挖")
	assert_eq((r["added"] as Array).size(), 16, "25 − 9 = 16 格被补上")


func test_a_cut_beam_is_refused_as_beam_cut() -> void:
	# 5×5 上两块 2×4（左右各贴边）+ 一根**一格宽**的桥 (2,0)：腐蚀把桥与贴边那一列一起吃掉
	# ⇒ 一整块裂成两块（regions 1→2），而盘上的空隙前后都是连通的 1 块（voids 1→1）
	# ⇒ 恰好落在文档点名的「把细梁弄断」这一档上。
	var g := _rect(5, 5)
	var cells: Array[Vector2i] = []
	cells.append_array(_block(0, 0, 2, 4))
	cells.append_array(_block(3, 0, 2, 4))
	cells.append(Vector2i(2, 0))
	var r := SMOOTH.apply(cells, g, SMOOTH.MODE_ERODE)
	assert_false(bool(r["ok"]), "会把细梁弄断 ⇒ 必须拒绝（文档硬约束）")
	assert_eq(str(r["problem_kind"]), SMOOTH.KIND_BEAM_CUT, "分类要精确到「细梁弄断」")
	assert_gt(int(r["after"]["regions"]), int(r["before"]["regions"]), "格集的分量数确实变多了")
	assert_eq(int(r["before"]["void_regions"]), int(r["after"]["void_regions"]),
		"这一档只该动格集：空隙块数必须不变（否则就落到另一类问题）")
	assert_true((r["cells"] as Array).is_empty(), "被拒的结果必须为空（不落盘）")
	var problem: Array = r["problem"]
	assert_gt(problem.size(), 0, "必须指出「出问题的格」供 UI 高亮")
	assert_true(problem.has(Vector2i(2, 0)), "被腐蚀掉的桥格必须在问题格里（实际：%s）" % str(problem))
	assert_true(str(r["reason"]).contains("细梁"), "理由要读得懂（实际：%s）" % str(r["reason"]))


func test_two_holes_merging_is_refused_as_void_merged() -> void:
	# 外围**两格厚**（40 格）+ 一条竖向内刺 (3,2)/(3,3)/(3,4)，把内部 3×3 空隙拦成左右两块。
	# 腐蚀把内层与那根一格宽的内刺一起吃进外围（结果只剩 24 格外圈）：空隙 2 块并成 1 块，
	# 而格集前后都还是 1 块 ⇒ 归一为「两个洞意外连通」。
	var g := _rect(7, 7)
	var cells: Array[Vector2i] = []
	for y in 7:
		for x in 7:
			if x <= 1 or y <= 1 or x >= 5 or y >= 5:
				cells.append(Vector2i(x, y))
	cells.append_array([Vector2i(3, 2), Vector2i(3, 3), Vector2i(3, 4)])
	var r := SMOOTH.apply(cells, g, SMOOTH.MODE_ERODE)
	assert_false(bool(r["ok"]), "会把盘上的两块空隙并成一块 ⇒ 必须拒绝")
	assert_eq(str(r["problem_kind"]), SMOOTH.KIND_VOID_MERGED, "分类要精确到「缝隙填死」")
	assert_lt(int(r["after"]["void_regions"]), int(r["before"]["void_regions"]), "空隙块数确实变少了")
	assert_eq(int(r["before"]["void_regions"]), 2, "执行前：内部空隙被内刺拦成左右两块")
	assert_eq(int(r["after"]["void_regions"]), 1, "执行后：并成完整的一块")
	assert_eq(int(r["before"]["regions"]), int(r["after"]["regions"]), "这一档只该动空隙：格集块数必须不变")
	var problem: Array = r["problem"]
	assert_gt(problem.size(), 0, "必须指出「出问题的格」供 UI 高亮")
	assert_true(problem.has(Vector2i(3, 3)), "被吃掉的拦腰内刺必须在问题格里（实际：%s）" % str(problem))
	assert_true(str(r["reason"]).contains("缝隙"), "理由要读得懂（实际：%s）" % str(r["reason"]))


func test_hand_edited_cells_stay_put_and_are_reported() -> void:
	var g := _rect(7, 7)
	var r := SMOOTH.apply(_block(1, 1, 5, 5), g, SMOOTH.MODE_ERODE,
		{"hand_edited": _cells([1, 1])})
	assert_true(bool(r["ok"]), "保护一格不该让操作失败（实际：%s）" % str(r["reason"]))
	assert_eq(int(r["count"]), 10, "3×3 结果 + 被保护的 (1,1) = 10 格")
	assert_true((r["cells"] as Array).has(Vector2i(1, 1)), "手工格要保持原状（本来在集合里就仍在）")
	assert_eq(r["protected"], _cells([1, 1]), "被保护的手工格必须原样列进 protected")
	assert_ne(str(r["reason"]), "", "跳过必须说出来（不许静默忽略）")
	assert_true(str(r["reason"]).contains("手工"), "理由要读得懂（实际：%s）" % str(r["reason"]))
	# 无关的手工格（本来就不会被改到）不该虚报「跳过」
	var none := SMOOTH.apply(_block(1, 1, 5, 5), g, SMOOTH.MODE_ERODE, {"hand_edited": _cells([6, 6])})
	assert_true((none["protected"] as Array).is_empty(), "没被改到的格不算跳过")
	assert_eq(str(none["reason"]), "", "没有真的跳过任何格 ⇒ 理由为空")


func test_protection_cannot_rescue_a_broken_connectivity() -> void:
	# 保护桥格 (2,0) 也救不回来：两侧贴边的那一列仍会被挖掉，桥自己反而成了孤立的一块
	# （regions 1→3）⇒ 照样必须拒绝（保护 ≠ 放行）。
	var g := _rect(5, 5)
	var cells: Array[Vector2i] = []
	cells.append_array(_block(0, 0, 2, 4))
	cells.append_array(_block(3, 0, 2, 4))
	cells.append(Vector2i(2, 0))
	var r := SMOOTH.apply(cells, g, SMOOTH.MODE_ERODE, {"hand_edited": _cells([2, 0])})
	assert_false(bool(r["ok"]), "手工格保护不改变「该拒绝就拒绝」")
	assert_eq(str(r["problem_kind"]), SMOOTH.KIND_BEAM_CUT, "分类不变")
func test_bad_input_is_rejected_with_readable_reason() -> void:
	assert_false(bool(SMOOTH.apply([Vector2i(0, 0)], null, SMOOTH.MODE_ERODE)["ok"]),
		"空盘应被拒（判界必须走网格，不许按包围盒）")
	assert_false(bool(SMOOTH.apply([Vector2i(0, 0)], _rect(3, 3), "sharpen")["ok"]),
		"未知模式应被拒，不得静默按腐蚀 / 膨胀处理")
	assert_false(bool(SMOOTH.apply("nope", _rect(3, 3), SMOOTH.MODE_ERODE)["ok"]),
		"不支持的容器类型应被拒")
	var big: Array[Vector2i] = []
	for i in (SMOOTH.MAX_CELL_BUDGET + 1):
		big.append(Vector2i(i, 0))
	var over := SMOOTH.apply(big, _rect(3, 3), SMOOTH.MODE_ERODE)
	assert_false(bool(over["ok"]), "超过 MAX_CELL_BUDGET 应被拒（事前硬阻）")
	assert_true(str(over["reason"]).contains(str(SMOOTH.MAX_CELL_BUDGET)),
		"理由要说出上限（实际：%s）" % str(over["reason"]))


func test_output_is_sorted_and_reproducible() -> void:
	var g := _rect(7, 7)
	var src := _block(1, 1, 5, 5)
	var a := SMOOTH.apply(src, g, SMOOTH.MODE_ERODE)
	var b := SMOOTH.apply(src, g, SMOOTH.MODE_ERODE)
	assert_eq(a["cells"], b["cells"], "两次同输入必须逐项相同（字典遍历顺序不作数）")
	assert_eq(a["removed"], b["removed"], "removed 也要可复现")
	var got: Array = (a["cells"] as Array).duplicate()
	var want: Array = (a["cells"] as Array).duplicate()
	want.sort_custom(func(p: Vector2i, q: Vector2i) -> bool:
		if p.y != q.y:
			return p.y < q.y
		return p.x < q.x)
	assert_eq(got, want, "输出必须已按 (y, x) 升序")
	assert_eq(int(a["count"]), (a["cells"] as Array).size(), "count 必须等于 cells.size()（守恒）")
	var empty := SMOOTH.apply([], g, SMOOTH.MODE_DILATE)
	assert_true(bool(empty["ok"]), "空集是合法输入（不是错误）")
	assert_eq(int(empty["count"]), 0, "空集平滑出 0 格")


func test_describe_reads_like_a_sentence() -> void:
	var g := _rect(7, 7)
	var ok := SMOOTH.apply(_block(1, 1, 5, 5), g, SMOOTH.MODE_ERODE, {"hand_edited": _cells([1, 1])})
	var text := SMOOTH.describe(ok)
	assert_true(text.contains("腐蚀"), "文案要说出做的是哪种（实际：%s）" % text)
	assert_true(text.contains("跳过"), "跳过了手工格就要说出来（实际：%s）" % text)
	assert_true(SMOOTH.describe(SMOOTH.apply([Vector2i(0, 0)], null, SMOOTH.MODE_ERODE)).begins_with("未执行"),
		"失败也要给出可读文案")


# ==================== 测试辅助 ====================

## 一块 x 起 `x0`、宽 `w`，y 起 `y0`、高 `h` 的实心矩形格集（写法短，顺序刻意不排序）。
func _block(x0: int, y0: int, w: int, h: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in h:
		for dx in w:
			out.append(Vector2i(x0 + dx, y0 + dy))
	return out


## 扁平的 [x, y, x, y, ...] → 格坐标数组。
func _cells(flat: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var i := 0
	while i + 1 < flat.size():
		out.append(Vector2i(int(flat[i]), int(flat[i + 1])))
		i += 2
	return out


func _rect(rows: int, cols: int) -> RectGrid:
	var g := RectGrid.new()
	g.setup(rows, cols)
	return g
