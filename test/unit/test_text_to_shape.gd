# test_text_to_shape.gd —— 「文字 / 手绘轮廓 → 格集」（核心缺口 #2）的钉子。
#
# 背景：core/shape_dag.gd 的词汇表早已登记 "text" / "freehand"，`primitive_to_builder()` 也如实报
#   「本仓无构建器」，但全仓没有「文字 / 笔迹 → 格集」这一层。本轮由 core/text_to_shape.gd 补上；
#   本文件把它的关键行为**写死**（不是自证：期望值全部手算 / 硬编码，一眼能复核）。
#
# 覆盖：
#   ① 已知点阵的简单字符 ⇒ 格数 + 逐格位置写死（scale=1 / scale=2 两档，防漂移）
#   ② 空串 / 未知字符 / 非法点阵 / 超宽高 ⇒ ok=false + reason 非空 + cells 为空（不留半成品）
#   ③ 手绘点太少 / 自交 / 退化 ⇒ ok=false + reason 非空
#   ④ 有洞的形状盘（挖洞盘 + 环形 annulus）⇒ 判界走 grid.in_board()、**不是包围盒**；
#      输出的每一格都在 all_positions() 内，洞格绝不被写入
#   ⑤ 确定性：同输入两次调用逐位相同（文字与轮廓各一组）
#   ⑥ 给 DAG 的参数表真能被 ShapeDag 词汇表接受并往返落盘（不吹"已接线"）
extends GutTest

const TTS := preload("res://core/text_to_shape.gd")
const SG := preload("res://core/shape_generator.gd")
const SHAPE_DAG := preload("res://core/shape_dag.gd")
## 唯一事实来源（常量 + DP）：被测模块只依赖它。
const SL := preload("res://core/stroke_limits.gd")
## 仅用于**对拍**：ui 侧那份 DP / 量化必须与 StrokeLimits 逐位相同（防两份实现漂移）。
## 注意：测试可以引用 ui（生产代码 core/ 下不得出现 res://ui/ —— 由 _grep 证据在汇报里确认）。
const DL := preload("res://ui/drawing_layer.gd")

## 3×3 的 "A"：6 个填充格（(1,0),(0,1),(2,1),(0,2),(1,2),(2,2)）。
const GLYPH_A: Array = [".#.", "#.#", "###"]
## 3×3 的 "B"：7 个填充格（左侧竖条 + 上/中横杠）。
const GLYPH_B: Array = ["##.", "#.#", "##."]


# ==================== ① 已知点阵：格数与形状写死 ====================

func test_glyph_A_scale1_has_six_pinned_cells() -> void:
	var grid = _rect(5, 5)
	var r: Dictionary = TTS.text_to_cells("A", {"A": GLYPH_A}, 1, grid)
	assert_true(bool(r["ok"]), "盘内 'A' 应成功：%s" % str(r["reason"]))
	assert_eq(int((r["cells"] as Dictionary).size()), 6, "3×3 点阵 'A' 的填充格数（硬编码期望：6）")
	assert_eq(_cells_str(r["cells"]), "1,0;0,1;2,1;0,2;1,2;2,2",
			"逐格位置必须稳定（硬编码期望，防漂移）")


func test_glyph_A_scale2_is_a_2x2_block_per_dot() -> void:
	var grid = _rect(8, 8)
	var r: Dictionary = TTS.text_to_cells("A", {"A": GLYPH_A}, 2, grid)
	assert_true(bool(r["ok"]), "盘内 'A' (scale=2) 应成功：%s" % str(r["reason"]))
	assert_eq(int((r["cells"] as Dictionary).size()), 24, "6 个点阵像素 × 2×2 放大 = 24 格（硬编码期望）")
	for p: Vector2i in [Vector2i(2, 0), Vector2i(3, 0), Vector2i(2, 1), Vector2i(3, 1)]:
		assert_true((r["cells"] as Dictionary).has(p),
				"点阵 (1,0) 放大后应占 %s（2×2 块的左上角）" % str(p))
	assert_false((r["cells"] as Dictionary).has(Vector2i(4, 0)),
			"点阵 (1,0) 的块只有 x=2,3；x=4 是空列，不该有格")


# ==================== ② 拒绝：空串 / 未知字符 / 非法点阵 / 超宽高 ====================

func test_empty_text_is_rejected() -> void:
	var r: Dictionary = TTS.text_to_cells("", {"A": GLYPH_A}, 1, _rect(5, 5))
	_expect_reject(r, "空串必须拒绝")
	assert_string_contains(str(r["reason"]), "空", "原因应可读地点出「空串」")


func test_unknown_character_is_rejected() -> void:
	var r: Dictionary = TTS.text_to_cells("Z", {"A": GLYPH_A}, 1, _rect(5, 5))
	_expect_reject(r, "font_mask 里没有 'Z' ⇒ 拒绝（不猜字形）")
	assert_string_contains(str(r["reason"]), "Z", "原因应点名未知字符")


func test_malformed_glyph_is_rejected() -> void:
	var ragged: Dictionary = TTS.text_to_cells("A", {"A": ["##", "#"]}, 1, _rect(5, 5))
	_expect_reject(ragged, "行长不一致 ⇒ 拒绝")
	assert_string_contains(str(ragged["reason"]), "行长", "原因应指出行长不一致")

	var illegal: Dictionary = TTS.text_to_cells("A", {"A": ["#?", ".."]}, 1, _rect(5, 5))
	_expect_reject(illegal, "点阵含字母表外字符 ⇒ 拒绝")
	assert_string_contains(str(illegal["reason"]), "非法字符", "原因应指出非法字符")

	var blank: Dictionary = TTS.text_to_cells("A", {"A": ["..", ".."]}, 1, _rect(5, 5))
	_expect_reject(blank, "全空点阵 ⇒ 不成形状，拒绝")


func test_oversized_text_is_rejected() -> void:
	# "AB" 在 2×2 的盘上：每个字形宽 3 + 1 空列 = 7 列，远超盘宽 2 ⇒ 整体拒绝（不裁剪）。
	var r: Dictionary = TTS.text_to_cells("AB", {"A": GLYPH_A, "B": GLYPH_B}, 1, _rect(2, 2))
	_expect_reject(r, "超宽文字必须拒绝")
	assert_string_contains(str(r["reason"]), "越界", "原因应指出越界（并提示挪 origin / 调小 scale）")


func test_invalid_scale_and_null_grid_are_rejected() -> void:
	_expect_reject(TTS.text_to_cells("A", {"A": GLYPH_A}, 0, _rect(5, 5)), "scale=0 非法")
	_expect_reject(TTS.text_to_cells("A", {"A": GLYPH_A}, -1, _rect(5, 5)), "scale<0 非法")
	_expect_reject(TTS.text_to_cells("A", {"A": GLYPH_A}, 1, null), "网格为空 ⇒ 拒绝（不猜盘面）")


# ==================== ③ 手绘轮廓：点太少 / 自交 / 退化 ====================

func test_outline_too_few_points_is_rejected() -> void:
	var r: Dictionary = TTS.outline_to_cells(
			PackedVector2Array([Vector2(1.5, 1.5), Vector2(4.5, 1.5)]), _rect(8, 8), 0.05)
	_expect_reject(r, "2 个点不成闭合多边形")


func test_outline_self_intersection_is_rejected() -> void:
	# 蝴蝶结：段 (0,0)-(2,2) 与段 (2,0)-(0,2) 相交。
	var bowtie := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(2.0, 2.0), Vector2(2.0, 0.0), Vector2(0.0, 2.0)])
	var r: Dictionary = TTS.outline_to_cells(bowtie, _rect(8, 8), 0.05)
	_expect_reject(r, "自交轮廓必须拒绝")
	assert_string_contains(str(r["reason"]), "自交", "原因应指出自交（而不是含糊的失败）")


func test_outline_degenerate_is_rejected() -> void:
	var same := PackedVector2Array([
		Vector2(1.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 1.0)])
	_expect_reject(TTS.outline_to_cells(same, _rect(8, 8), 0.05), "全部同点 ⇒ 退化")


# ==================== ③' 手绘轮廓：正常栅格化 + 裁剪 ====================

func test_outline_triangle_rasterizes_pinned_cells() -> void:
	# 三角形 (1.5,1.5)-(6.5,1.5)-(1.5,6.5)：顶点取半整数 ⇒ 格心永不落在边界上（无歧义）。
	# 内部 = x>1.5 ∧ y>1.5 ∧ x+y<8 ⇒ x≥2, y≥2, x+y≤7 ⇒ 手算 10 格。
	var tri := PackedVector2Array([
		Vector2(1.5, 1.5), Vector2(6.5, 1.5), Vector2(1.5, 6.5)])
	var r: Dictionary = TTS.outline_to_cells(tri, _rect(8, 8), 0.05)
	assert_true(bool(r["ok"]), "三角形应栅格化成功：%s" % str(r["reason"]))
	assert_eq(int((r["cells"] as Dictionary).size()), 10, "手算期望：10 格")
	assert_eq(_cells_str(r["cells"]), "2,2;3,2;4,2;5,2;2,3;3,3;4,3;2,4;3,4;2,5",
			"逐格位置必须稳定（硬编码期望）")
	assert_eq(int(r["clipped"]), 0, "三角形完全在盘内 ⇒ 无裁剪")
	assert_eq(float(r["epsilon"]), float(SL.EPSILON),
			"tolerance>0 时 epsilon 就是传入容差（此处传了与手绘落盘相同的 0.05）")
	assert_eq((r["simplified"] as PackedVector2Array).size(), 3, "三角形 3 个角都在 ⇒ 抽稀后仍是 3 点")


func test_outline_clips_to_board_and_reports_clipped_count() -> void:
	# 大三角形 (2.5,2.5)-(9.5,2.5)-(2.5,9.5) 在 6×6 盘上：
	# 内部 = x>2.5 ∧ y>2.5 ∧ x+y<12 ⇒ 共 21 格；其中盘内 9 格、盘外（裁剪）12 格（手算）。
	var tri := PackedVector2Array([
		Vector2(2.5, 2.5), Vector2(9.5, 2.5), Vector2(2.5, 9.5)])
	var grid = _rect(6, 6)
	var r: Dictionary = TTS.outline_to_cells(tri, grid, 0.05)
	assert_true(bool(r["ok"]), "裁剪后仍有格 ⇒ 成功：%s" % str(r["reason"]))
	assert_eq(int((r["cells"] as Dictionary).size()), 9, "盘内手算期望：9 格")
	assert_eq(int(r["clipped"]), 12, "裁剪量不隐藏：盘外 12 格（手算期望）")
	_assert_all_in_board(r["cells"], grid)


func test_outline_tolerance_follows_handdraw_constant() -> void:
	# 顶边中点偏移 0.05（= StrokeLimits.EPSILON，手绘落盘同一枚常量）。DP 判据是 `max_d > epsilon`，
	# 0.05 不大于 0.05 ⇒ 默认容差下应被抹掉；容差 0.001 时应保留。⇒ 证明容差口径确实是手绘那套。
	var jittery := PackedVector2Array([
		Vector2(1.5, 1.5), Vector2(3.0, 1.55), Vector2(4.5, 1.5),
		Vector2(4.5, 4.5), Vector2(1.5, 4.5),
	])
	var grid = _rect(8, 8)
	var def: Dictionary = TTS.outline_to_cells(jittery, grid, -1.0)
	assert_true(bool(def["ok"]), "默认容差应能栅格化：%s" % str(def["reason"]))
	assert_eq(float(def["epsilon"]), float(SL.EPSILON),
			"tolerance ≤ 0 ⇒ 取 StrokeLimits.EPSILON（与手绘落盘同一枚常量）")
	assert_eq((def["simplified"] as PackedVector2Array).size(), 4,
			"0.05 的抖动在容差 0.05 下被抹掉 ⇒ 4 个角")
	assert_eq(int((def["cells"] as Dictionary).size()), 9, "抹平后是 3×3 = 9 格的方框")

	var tight: Dictionary = TTS.outline_to_cells(jittery, grid, 0.001)
	assert_true(bool(tight["ok"]), "小容差应能栅格化：%s" % str(tight["reason"]))
	assert_eq((tight["simplified"] as PackedVector2Array).size(), 5,
			"容差 0.001 < 抖动 0.05 ⇒ 抖动点必须保留（容差旋钮真的生效）")


# ==================== ④ 有洞的形状盘：判界走 in_board，不是包围盒 ====================

func test_holed_grid_uses_in_board_not_bounding_box() -> void:
	# 8×6 挖洞盘，洞在 (5,0)。'A' 原点 (0,0) 时占 (0..2, 0..2)，碰不到洞。
	var grid = SG.to_adjacency_grid("holed_grid", {
		"rows": 6, "cols": 8, "holes": [{"x": 5, "y": 0}],
	})
	var ok_res: Dictionary = TTS.text_to_cells("A", {"A": GLYPH_A}, 1, grid)
	assert_true(bool(ok_res["ok"]), "盘内文字应成功：%s" % str(ok_res["reason"]))
	_assert_all_in_board(ok_res["cells"], grid)
	assert_false((ok_res["cells"] as Dictionary).has(Vector2i(5, 0)), "洞格不得被写入")

	# 把文字挪到会覆盖洞格 (5,0) 的位置（dot (1,0) → (5,0)）：若判界用 cols×rows 包围盒，
	# 这里会「成功」并把洞格当普通格；必须**整体拒绝**（证明 in_board() 真被问到）。
	var bad_res: Dictionary = TTS.text_to_cells("A", {"A": GLYPH_A}, 1, grid, Vector2i(4, 0))
	_expect_reject(bad_res, "覆盖洞格的文字必须整体拒绝（判界走 in_board，不走包围盒）")
	assert_string_contains(str(bad_res["reason"]), "越界", "原因应指出越界")


func test_annulus_grid_never_returns_out_of_board_cells() -> void:
	# 环形 annulus（内圆挖空）——外径 6 / 内径 3，盘心 (6,6)。原点 (0,0) 到盘心 ≈8.49 > 6
	# ⇒ (0,0) 既不在环上也不在洞内（是盘外）⇒ 文字整体拒绝；绝不会把盘外/洞格吐出来。
	var grid = SG.to_adjacency_grid("annulus", {"outer_radius": 6, "inner_radius": 3})
	var res: Dictionary = TTS.text_to_cells("A", {"A": GLYPH_A}, 1, grid)
	_expect_reject(res, "环盘原点在盘外 ⇒ 必须拒绝（包围盒口径会误判为盘内）")

	# 正例：把 1×1 真字形放到环上某个**真实格**（all_positions() 的成员）⇒ 成功且每格都在盘内。
	var positions: Array = grid.all_positions()
	assert_gt(positions.size(), 0, "环盘应非空（前提检查）")
	var p: Vector2i = positions[0]
	var one: Dictionary = TTS.text_to_cells("I", {"I": ["#"]}, 1, grid, p)
	assert_true(bool(one["ok"]), "环上单格字应成功：%s" % str(one["reason"]))
	assert_eq(int((one["cells"] as Dictionary).size()), 1, "1×1 字形 = 1 格")
	_assert_all_in_board(one["cells"], grid)


# ==================== ⑤ 确定性：同输入两次逐位相同 ====================

func test_text_and_outline_outputs_are_bit_identical_across_calls() -> void:
	var grid = _rect(16, 16)
	var mask := {"A": GLYPH_A, "B": GLYPH_B}
	var t1: Dictionary = TTS.text_to_cells("AB", mask, 2, grid)
	var t2: Dictionary = TTS.text_to_cells("AB", mask, 2, grid)
	assert_true(bool(t1["ok"]), "16×16 盘上 'AB' 应成功：%s" % str(t1["reason"]))
	assert_eq(_fingerprint(t1), _fingerprint(t2), "文字：同输入两次必须逐位相同")
	# 手算：A/B 各 6 个点阵像素 × 2×2 = 24 格，两字共 48。字距 = 1 逻辑列 × scale = x 6,7 两列为空。
	assert_eq(int((t1["cells"] as Dictionary).size()), 48, "A(24) + B(24) = 48 格（手算期望）")
	assert_false((t1["cells"] as Dictionary).has(Vector2i(6, 0)), "字距列 x=6 必须为空")
	assert_false((t1["cells"] as Dictionary).has(Vector2i(7, 0)), "字距列 x=7 必须为空")
	assert_true((t1["cells"] as Dictionary).has(Vector2i(8, 0)), "B 的 (0,0) 应从 x=8 开始（pen 推进 = 3*2+1*2）")

	var tri := PackedVector2Array([
		Vector2(1.5, 1.5), Vector2(6.5, 1.5), Vector2(1.5, 6.5)])
	var o1: Dictionary = TTS.outline_to_cells(tri, grid, 0.05)
	var o2: Dictionary = TTS.outline_to_cells(tri, grid, 0.05)
	assert_eq(_fingerprint(o1), _fingerprint(o2), "轮廓：同输入两次必须逐位相同")


# ==================== ⑥ DAG 参数表：落在既有词汇内且可往返落盘 ====================

func test_dag_params_are_accepted_by_shape_dag_and_roundtrip() -> void:
	assert_true(ShapeDag.PRIMITIVE_SHAPES.has("text"), "前提：DAG 词汇表已登记 text")
	assert_true(ShapeDag.PRIMITIVE_SHAPES.has("freehand"), "前提：DAG 词汇表已登记 freehand")

	var dag = SHAPE_DAG.new()
	var rt: Dictionary = dag.add_primitive("t", "text", TTS.text_dag_params("A", 2))
	assert_true(bool(rt["ok"]), "ShapeDag 必须接受 text 参数表：%s" % str(rt["error"]))
	var tri := PackedVector2Array([
		Vector2(1.5, 1.5), Vector2(6.5, 1.5), Vector2(1.5, 6.5)])
	var rf: Dictionary = dag.add_primitive("f", "freehand", TTS.freehand_dag_params(tri, 0.05))
	assert_true(bool(rf["ok"]), "ShapeDag 必须接受 freehand 参数表：%s" % str(rf["error"]))
	assert_eq(dag.node_count(), 2, "两个 primitive 都该进图")
	assert_eq(str(dag.node("t")["params"]["kind"]), "text", "text 参数自带 kind 标记")
	assert_eq(str(dag.node("f")["params"]["kind"]), "freehand", "freehand 参数自带 kind 标记")

	# 落盘往返：参数必须是 quantize_value / JSON 安全的 ⇒ 与既有 DAG 节点同等待遇。
	var data: Dictionary = dag.to_dict()
	var back = SHAPE_DAG.new()
	var rd: Dictionary = back.from_dict(data)
	assert_true(bool(rd["ok"]), "to_dict → from_dict 必须成功：%s" % str(rd["error"]))
	assert_eq(JSON.stringify(back.to_dict()), JSON.stringify(data), "往返后逐字段一致")

	var parsed: Variant = JSON.parse_string(JSON.stringify(data))
	assert_true(parsed is Dictionary, "to_dict 必须能过 JSON.stringify → parse（落盘前提）")
	var back2 = SHAPE_DAG.new()
	assert_true(bool(back2.from_dict(parsed)["ok"]), "JSON 往返后仍可读回")


# ==================== ⑦ 唯一事实来源：core/stroke_limits.gd ⇄ ui 侧逐位对拍 ====================

func test_stroke_limits_match_drawing_layer_bit_for_bit() -> void:
	# core 侧自持 DP（不依赖 ui，防分层倒置）与 ui/drawing_layer.gd 的 DP 是两份同源实现；
	# 这条对拍是**防两份实现漂移的关键**：同一输入必须逐位相同。
	var samples: Array = [
		PackedVector2Array([Vector2(0, 0), Vector2(5, 0), Vector2(10, 0), Vector2(15, 0), Vector2(20, 0)]),
		PackedVector2Array([Vector2(0, 0), Vector2(10, 10), Vector2(20, 0)]),
		PackedVector2Array([Vector2(1.5, 1.5), Vector2(3.0, 1.55), Vector2(4.5, 1.5),
				Vector2(4.5, 4.5), Vector2(1.5, 4.5)]),
		_jagged_near_line(),
		PackedVector2Array([Vector2(7, 7)]),
		PackedVector2Array(),
	]
	var epsilons: Array = [-1.0, 0.0, 0.001, 0.05, 1.0, 100.0]
	var checked := 0
	for pts: PackedVector2Array in samples:
		for eps: float in epsilons:
			var a: PackedVector2Array = SL.simplify_stroke(pts, eps)
			var b: PackedVector2Array = DL.simplify_stroke(pts, eps)
			assert_eq(_pts_str(a), _pts_str(b),
					"DP 对拍必须逐位相同（n=%d, eps=%.3f）：core=[%s] ui=[%s]" % [
						pts.size(), eps, _pts_str(a), _pts_str(b)])
			checked += 1
	assert_gt(checked, 20, "至少对拍 20 组以上，否则本用例空转（实际 %d）" % checked)

	# 常量别名：ui 侧的值必须就是 StrokeLimits 的值（别名掉链子会在这里当场变红）。
	assert_eq(float(DL.SIMPLIFY_EPSILON), float(SL.EPSILON),
			"DrawingLayer.SIMPLIFY_EPSILON 必须是 StrokeLimits.EPSILON 的别名")
	assert_eq(float(DL.BOARD_UNIT_PER_CELL), float(SL.BOARD_UNIT_PER_CELL),
			"DrawingLayer.BOARD_UNIT_PER_CELL 必须别名化（同源）")
	assert_eq(float(DL.QUANT_STEP), float(SL.QUANT_STEP),
			"DrawingLayer.QUANT_STEP 必须是 StrokeLimits.QUANT_STEP 的别名")

	# 量化 / 反量化也对拍。
	for p: Vector2 in [Vector2(0, 0), Vector2(12.3456789, -3.1415926),
			Vector2(0.00005, 0.00015), Vector2(-7.5, 1234.56789)]:
		assert_eq(SL.quantize_point(p), DL.quantize_point(p), "quantize_point 必须逐位相同（%s）" % str(p))
	assert_eq(SL.dequantize_point(Vector2i(3, -9)), DL.dequantize_point(Vector2i(3, -9)),
			"dequantize_point 必须逐位相同")


# ==================== 测试内辅助 ====================

func _rect(rows: int, cols: int):
	return SG.to_adjacency_grid("holed_grid", {"rows": rows, "cols": cols})


func _expect_reject(r: Dictionary, why: String) -> void:
	assert_false(bool(r["ok"]), "%s（实际 ok=true）" % why)
	assert_eq((r["cells"] as Dictionary).size(), 0, "%s ⇒ 不得留下半成品格" % why)
	assert_ne(str(r["reason"]).strip_edges(), "", "%s ⇒ 必须给可读原因" % why)


func _assert_all_in_board(cells: Dictionary, grid) -> void:
	assert_gt(cells.size(), 0, "前提：要有格可查")
	var positions: Array = grid.all_positions()
	for p: Vector2i in cells.keys():
		assert_true(grid.in_board(p), "%s 必须被网格判为盘内" % str(p))
		assert_true(positions.has(p), "%s 必须出现在 all_positions() 内" % str(p))


## 规范格序（按 y 再 x），便于与硬编码字符串逐字对照。
func _sorted(cells: Dictionary) -> Array:
	var keys: Array = cells.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	return keys


func _cells_str(cells: Dictionary) -> String:
	var parts := PackedStringArray()
	for p: Vector2i in _sorted(cells):
		parts.append("%d,%d" % [p.x, p.y])
	return ";".join(parts)


## 逐位指纹：ok / reason / 格集（规范序）/ epsilon / 抽稀点 —— 用于确定性对拍。
func _fingerprint(r: Dictionary) -> Array:
	var out: Array = [bool(r.get("ok", false)), str(r.get("reason", ""))]
	for p: Vector2i in _sorted(r.get("cells", {})):
		out.append("%d,%d" % [p.x, p.y])
	if r.has("epsilon"):
		out.append("%.9f" % float(r["epsilon"]))
	if r.has("simplified"):
		for v: Vector2 in (r["simplified"] as PackedVector2Array):
			out.append("%.6f/%.6f" % [v.x, v.y])
	return out


## 点列的规范字符串（对拍 DP 输出用；精度拉到 9 位小数，肉眼不可辨的差异也要暴露）。
func _pts_str(pts: PackedVector2Array) -> String:
	var parts := PackedStringArray()
	for v: Vector2 in pts:
		parts.append("%.9f/%.9f" % [v.x, v.y])
	return ";".join(parts)


## 200 点、振幅 0.02 的近共线锯齿（手绘最常见的"长直线 + 抖动"形态，专门压 DP 的等价性）。
func _jagged_near_line() -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 200:
		pts.append(Vector2(float(i) * 0.5, 0.02 if i % 2 == 0 else -0.02))
	pts.append(Vector2(100.0, 0.0))
	return pts
