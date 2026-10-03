# test_drawing_stroke_limits.gd —— 手绘轮廓点数的硬上限 / Douglas-Peucker 抽稀 / 坐标量化
# 对应任务 1（文档 E②③）：
#   ① 超长输入被抽稀到 ≤ MAX_STROKE_POINTS
#   ② 抽稀后形状误差在容差内（首尾保留、共线中点去掉、超容差拐点保留）
#   ③ 量化往返：量化→反量化误差 ≤ 步长，且两次量化结果完全相同
extends GutTest


func _new_layer() -> DrawingLayer:
	var layer: DrawingLayer = load("res://ui/drawing_layer.tscn").instantiate()
	add_child_autofree(layer)
	return layer


# ============ ② Douglas-Peucker（纯函数） ============

# 共线中点必须被去掉，仅保留首尾
func test_simplify_removes_collinear_midpoints_keeps_ends() -> void:
	var pts := PackedVector2Array([
		Vector2(0, 0), Vector2(5, 0), Vector2(10, 0), Vector2(15, 0), Vector2(20, 0),
	])
	var out := DrawingLayer.simplify_stroke(pts, DrawingLayer.SIMPLIFY_EPSILON)
	assert_eq(out.size(), 2, "共线中点应被全部去掉，只留首尾")
	assert_eq(out[0], Vector2(0, 0), "首点保留")
	assert_eq(out[out.size() - 1], Vector2(20, 0), "尾点保留")


# 偏离超过容差的拐点必须保留（形状不走样）
func test_simplify_keeps_corners_beyond_tolerance() -> void:
	var corner := PackedVector2Array([Vector2(0, 0), Vector2(10, 10), Vector2(20, 0)])
	var out := DrawingLayer.simplify_stroke(corner, DrawingLayer.SIMPLIFY_EPSILON)
	assert_eq(out.size(), 3, "拐点偏离 10 ≫ 容差 0.05，必须保留")


# 抽稀后形状误差不超过容差：用全程距简化折线的最大垂距衡量
func test_simplify_error_within_tolerance() -> void:
	var pts := PackedVector2Array()
	# 一条带 0.02 振幅锯齿的近似直线（< 容差 0.05）→ 锯齿应被抹平
	for i in 200:
		var x := float(i) * 0.5
		var y := 0.02 if i % 2 == 0 else -0.02
		pts.append(Vector2(x, y))
	pts.append(Vector2(100.0, 0.0))
	var out := DrawingLayer.simplify_stroke(pts, DrawingLayer.SIMPLIFY_EPSILON)
	assert_true(out.size() < pts.size(), "锯齿应被抽稀")
	var worst := _max_deviation(pts, out)
	assert_true(worst <= DrawingLayer.SIMPLIFY_EPSILON + 0.0001,
			"被删点的最大偏离应 ≤ 容差（实际 %.6f）" % worst)


# ============ ① 点数硬上限 ============

func test_hard_cap_simplifies_oversized_input() -> void:
	var pts := PackedVector2Array()
	# 4000 点、振幅 0.001 的近共线锯齿 → 远低于容差，应收敛到首尾
	for i in 4000:
		pts.append(Vector2(float(i) * 0.01, sin(float(i) * 0.01) * 0.001))
	assert_true(pts.size() > DrawingLayer.MAX_STROKE_POINTS, "构造的输入须超过硬上限")
	var out := DrawingLayer.enforce_stroke_limit(pts)
	assert_true(out.size() <= DrawingLayer.MAX_STROKE_POINTS, "超长输入必须被压到硬上限以内")
	assert_true(out.size() < pts.size(), "必须真正发生抽稀")
	assert_eq(out[0], pts[0], "首点保留")
	assert_eq(out[out.size() - 1], pts[pts.size() - 1], "尾点保留")


# 未超上限的输入原样返回（不误伤正常手绘手感）
func test_hard_cap_leaves_normal_stroke_untouched() -> void:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(20, 0)])
	var out := DrawingLayer.enforce_stroke_limit(pts)
	assert_eq(out.size(), 3, "点数未超限时不得抽稀")


# 收笔路径兜底：直接塞超长点列的笔画也会被压到上限内
func test_finish_draw_enforces_cap() -> void:
	var layer := _new_layer()
	layer._start_draw(Vector2.ZERO)
	var pts: PackedVector2Array = layer._active_stroke["points"]
	for i in 3000:
		pts.append(Vector2(float(i), 0.0))
	layer._active_stroke["points"] = pts
	layer._finish_draw()
	assert_true(layer.strokes[0]["points"].size() <= DrawingLayer.MAX_STROKE_POINTS,
			"落笔后笔画点数必须 ≤ 硬上限")


# ============ ③ 坐标量化 ============

func test_quantize_roundtrip_error_within_step() -> void:
	var samples := [
		Vector2(0, 0),
		Vector2(12.3456789, -3.1415926),
		Vector2(0.00003, 0.00007),
		Vector2(99.99994, 0.00005),
		Vector2(-7.5, 1234.56789),
	]
	for p in samples:
		var q := DrawingLayer.quantize_point(p)
		var back := DrawingLayer.dequantize_point(q)
		assert_true((back - p).length() <= DrawingLayer.QUANT_STEP,
				"反量化误差应 ≤ 步长（点 %s）" % str(p))


func test_quantize_twice_is_identical() -> void:
	var samples := [
		Vector2(12.3456789, -3.1415926),
		Vector2(0.00005, 0.00015),
		Vector2(-7.5, 1234.56789),
	]
	for p in samples:
		var q1 := DrawingLayer.quantize_point(p)
		var q2 := DrawingLayer.quantize_point(DrawingLayer.dequantize_point(q1))
		assert_eq(q2, q1, "量化 → 反量化 → 再量化必须逐位相同（跨机器一致）")


# ============ 落盘全链路：整数落盘 + JSON 往返 + 旧档兼容 ============

func test_save_data_stores_integers_and_roundtrips() -> void:
	var layer := _new_layer()
	layer._start_draw(Vector2(12.3456789, -3.1415926))
	layer._active_stroke["points"].append(Vector2(50.0000049, 25.9999951))
	layer._finish_draw()
	var data := layer.get_save_data()
	assert_eq(int(data.get("v", 0)), DrawingLayer.SAVE_VERSION, "写当前版本号")
	var raw0: Array = data["strokes"][0]["points"][0]
	assert_true(raw0[0] is int and raw0[1] is int, "落盘坐标必须量化成整数")
	# 走真实落盘路径：JSON 文本 → parse
	var parsed: Dictionary = JSON.parse_string(JSON.stringify(data))
	var layer2 := _new_layer()
	layer2.load_save_data(parsed)
	assert_false(layer2.legacy_discarded(), "当前版本不应被判为旧格式")
	assert_eq(layer2.strokes.size(), 1, "应有 1 笔")
	var p0: Vector2 = layer2.strokes[0]["points"][0]
	assert_true(p0.distance_to(Vector2(12.3456789, -3.1415926)) <= DrawingLayer.QUANT_STEP,
			"JSON 往返后坐标误差 ≤ 量化步长")


# 旧档（v2：浮点直存、无 quant）必须仍能读
func test_v2_float_save_still_loads() -> void:
	var layer := _new_layer()
	layer.load_save_data({
		"v": 2,
		"strokes": [{
			"points": [[10.25, 20.5], [30.125, 40.0]],
			"color": "#1E88E5",
			"size": 4,
			"is_eraser": false,
		}],
		"current_color": 1,
		"current_size": 2,
	})
	assert_false(layer.legacy_discarded(), "v2 是棋盘坐标，必须继续可读（向后兼容）")
	assert_eq(layer.strokes.size(), 1, "v2 档应恢复 1 笔")
	assert_eq(layer.strokes[0]["points"][0], Vector2(10.25, 20.5), "旧档浮点坐标原样读回")
	assert_eq(layer.current_color, 1)


# v1（无 v 字段 = 屏幕坐标）仍需丢弃并置位告警
func test_v1_legacy_still_discarded() -> void:
	var layer := _new_layer()
	layer.load_save_data({
		"strokes": [{"points": [[10, 10], [20, 20]], "color": "#E53935", "size": 4}],
		"current_color": 1,
		"current_size": 1,
	})
	assert_eq(layer.strokes.size(), 0, "v1 屏幕坐标无法对齐棋盘 → 丢弃")
	assert_true(layer.legacy_discarded(), "应置位供 UI 提示")


# ============ 测试内距离辅助 ============

func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 <= 0.0:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _dist_to_polyline(p: Vector2, poly: PackedVector2Array) -> float:
	if poly.size() == 1:
		return p.distance_to(poly[0])
	var best := INF
	for i in range(poly.size() - 1):
		best = minf(best, _dist_to_segment(p, poly[i], poly[i + 1]))
	return best


func _max_deviation(orig: PackedVector2Array, simplified: PackedVector2Array) -> float:
	var worst := 0.0
	for p in orig:
		worst = maxf(worst, _dist_to_polyline(p, simplified))
	return worst
