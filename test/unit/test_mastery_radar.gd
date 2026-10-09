# test_mastery_radar.gd —— 掌握度雷达：三轴统计与画像判定
extends GutTest

const Radar := preload("res://core/mastery_radar.gd")


func _levels() -> Dictionary:
	return {
		"gen://o1/8/0": {"cleared": true, "best_stars": 3},
		"gen://o2/8/0": {"cleared": true, "best_stars": 2},
		"lib://o3/12/normal/1": {"cleared": true, "best_stars": 3},
		"gen://s1/8/0": {"cleared": true, "best_stars": 1},
		"gen://o1_s3/8/0": {"cleared": true, "best_stars": 3},
		"gen://combo/8/0": {"cleared": true, "best_stars": 3},
		"gen://z4/8/0": {"cleared": false},
	}


func test_counts_follow_cleared_only_and_multi_axis() -> void:
	var c := Radar.counts_from_levels(_levels())
	assert_eq(int(c["observe"]), 4, "o1/o2/o3/混合档各计一次观测")
	assert_eq(int(c["structure"]), 2, "s1 与混合档各计一次结构")
	assert_eq(int(c["conserve"]), 0, "只开局未通关不计入")
	assert_eq(int(c["other"]), 1, "combo 归入其它")
	assert_eq(int(c["total"]), 6, "合计 = 已通关条数")


func test_counts_on_empty_table() -> void:
	var c := Radar.counts_from_levels({})
	assert_eq(int(c["total"]), 0, "空表合计为 0")
	assert_eq(Radar.ratios(c), [0.0, 0.0, 0.0], "空表比例为全 0（不得除零）")


func test_ratios_normalize_to_max() -> void:
	var r := Radar.ratios({"observe": 4, "structure": 2, "conserve": 0})
	assert_eq(float(r[0]), 1.0, "最大值归一为 1")
	assert_eq(float(r[1]), 0.5, "一半应归一为 0.5")
	assert_eq(float(r[2]), 0.0, "0 仍是 0")


func test_dominant_and_persona() -> void:
	assert_eq(Radar.dominant({"observe": 0, "structure": 0, "conserve": 1}), "none", "样本不足时不判定")
	assert_eq(Radar.dominant({"observe": 9, "structure": 2, "conserve": 1}), "observe", "观测压倒性主导")
	assert_eq(Radar.dominant({"observe": 4, "structure": 4, "conserve": 4}), "balanced", "三轴齐平 → 均衡")
	assert_eq(Radar.dominant({"observe": 6, "structure": 2, "conserve": 1}), "observe", "差值大于 1 不算均衡")

	var p := Radar.persona({"observe": 9, "structure": 2, "conserve": 1})
	assert_eq(str(p["key"]), "observe", "画像 key 应为主导轴")
	assert_ne(str(p["title"]), "", "画像应有标题")
	assert_ne(str(p["blurb"]), "", "画像应有一段说明")
	assert_eq(str(Radar.persona({"observe": 0, "structure": 0, "conserve": 0})["key"]), "none", "空数据 → 未定型")


func test_polygon_points_geometry() -> void:
	var pts := Radar.polygon_points([1.0, 1.0, 1.0], Vector2(100, 100), 50.0)
	assert_eq(pts.size(), 3, "三轴雷达应有 3 个顶点")
	# 第一顶点从正上方开始（y 更小，x 相同）
	assert_almost_eq(pts[0].x, 100.0, 0.01, "正上方顶点 x 不变")
	assert_almost_eq(pts[0].y, 50.0, 0.01, "正上方顶点 y = center - radius")
	for p in pts:
		var d := (p - Vector2(100, 100)).length()
		assert_almost_eq(d, 50.0, 0.01, "满比例顶点都落在半径上")


func test_polygon_points_clamp_and_short_arrays() -> void:
	var pts := Radar.polygon_points([2.0, -1.0, 0.5], Vector2.ZERO, 10.0)
	assert_eq(pts.size(), 3, "顶点数 = 比例数")
	assert_almost_eq(pts[0].length(), 10.0, 0.01, "超过 1 的比例应被夹到 1")
	assert_almost_eq(pts[1].length(), 0.0, 0.01, "负比例应被夹到 0")
	assert_almost_eq(pts[2].length(), 5.0, 0.01, "0.5 应落在半半径")

	var one := Radar.polygon_points([1.0], Vector2.ZERO, 4.0)
	assert_eq(one.size(), 1, "单个比例也要能算（不得除零）")


func test_ring_points() -> void:
	var ring := Radar.ring_points(Vector2(10, 10), 20.0, 0.5)
	assert_eq(ring.size(), 3, "参考环默认三角形")
	for p in ring:
		assert_almost_eq((p - Vector2(10, 10)).length(), 10.0, 0.01, "半环半径 = 半径 × 0.5")


func test_axis_metadata() -> void:
	assert_eq(Radar.axis_ids().size(), 3, "三条轴")
	assert_eq(Radar.axis_name("structure"), "结构", "轴名可查")
	assert_eq(Radar.axis_name("nope"), "nope", "未知轴回显 id")
