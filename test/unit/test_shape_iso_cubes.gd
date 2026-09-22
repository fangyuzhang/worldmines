# test_shape_iso_cubes.gd —— 等轴菱面（60° 菱形 × 3 朝向）形状族的门禁（2026-09-22）
#
# 这一族是「看起来立体、实际是平面」的错觉盘。它成立的前提有四条，全部钉在这里：
#   ① 每格都是同一个 60° 菱形：四边等长(=1)、夹角 60°/120°；
#   ② 只有 3 种朝向，且数量严格 1:1:1（每 3 格 = 1 个「看起来立体的方块」）；
#   ③ 铺装数学上无缝无重叠（满足 2026-09-21 连通视觉契约）；
#   ④ 拓扑的每一条边，两端多边形**真的共边** —— 这是最强的一条：邻接表是几何反解出
#      来的（与同朝向面共边 0 个，必须跨朝向），一旦表写错或几何改了，这条立刻红。
extends GutTest

const ShapeGenerator := preload("res://core/shape_generator.gd")
const EPS := 0.00001


func test_cell_count_is_three_per_cube() -> void:
	var topo := ShapeGenerator.build_iso_cubes(4, 3)
	assert_eq((topo["positions"] as Array).size(), 4 * 3 * 3, "4×3 方块 = 36 格")
	# 三个洞 = 三个方块整体消失（-9 格）
	var holed := ShapeGenerator.build_iso_cubes(4, 3, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(3, 2)])
	assert_eq((holed["positions"] as Array).size(), 36 - 9, "每个洞删掉整整一个方块（3 格）")


func test_three_orientations_are_exactly_one_to_one_to_one() -> void:
	var topo := ShapeGenerator.build_iso_cubes(5, 5)
	var tally := {0: 0, 1: 0, 2: 0}
	for p: Dictionary in topo["positions"]:
		tally[int(p["x"]) % ShapeGenerator.ISO_FACE_COUNT] += 1
	assert_eq(tally[0], 25, "顶面 = 方块数")
	assert_eq(tally[1], 25, "右面 = 方块数")
	assert_eq(tally[2], 25, "左面 = 方块数")


func test_every_tile_is_a_unit_sixty_degree_rhombus() -> void:
	## 60° 菱形：四边等长 1，对角线比 √3:1，面积 sin60°。
	for rec: Dictionary in ShapeGenerator.iso_cells_geo(4, 4):
		var poly: PackedVector2Array = rec["poly"]
		assert_eq(poly.size(), 4, "每格 4 个顶点")
		for i in 4:
			var side := poly[i].distance_to(poly[(i + 1) % 4])
			assert_almost_eq(side, 1.0, EPS, "边长必须为 1（晶格单位）")
		# 菱形四角 = 两个 60°（锐）与两个 120°（钝），且必须交替 —— 这正是 60° 菱形
		var angs: Array[float] = []
		for i in 4:
			var e0 := poly[(i + 1) % 4] - poly[i]
			var e1 := poly[(i + 2) % 4] - poly[(i + 1) % 4]
			angs.append(rad_to_deg(absf(e0.angle_to(e1))))
		angs.sort()
		assert_almost_eq(angs[0], 60.0, 1e-3, "锐角必须是 60°")
		assert_almost_eq(angs[1], 60.0, 1e-3, "锐角必须是 60°")
		assert_almost_eq(angs[2], 120.0, 1e-3, "钝角必须是 120°")
		assert_almost_eq(angs[3], 120.0, 1e-3, "钝角必须是 120°")
		assert_almost_eq(_shoelace(poly), sin(deg_to_rad(60.0)), EPS, "面积 = sin60°")


func test_edge_direction_spectrum_is_exactly_three_axes() -> void:
	## 三种朝向 ⇒ 边方向只有 {30°, 90°, 150°}，且三档数量相等。
	## 这是「等轴测投影」的指纹：自由手绘的异形块方向谱会铺满 0~180°。
	var hist := {30: 0, 90: 0, 150: 0}
	for rec: Dictionary in ShapeGenerator.iso_cells_geo(4, 4):
		var poly: PackedVector2Array = rec["poly"]
		for i in 4:
			var a := rad_to_deg((poly[(i + 1) % 4] - poly[i]).angle())
			var bin_deg := int(round(fposmod(a, 180.0)))
			assert_true(hist.has(bin_deg), "边方向 %d° 不在 {30,90,150} 内" % bin_deg)
			hist[bin_deg] += 1
	assert_eq(hist[30], hist[90], "三个方向的边数必须相等（1:1:1 的朝向）")
	assert_eq(hist[90], hist[150], "三个方向的边数必须相等（1:1:1 的朝向）")


func test_every_topology_edge_is_a_real_shared_edge() -> void:
	## ★ 本族最强的一条：邻接表的每条边，两端多边形必须真的共用一条边（两个顶点重合）。
	## 邻接表是几何反解出来的（含「必须跨朝向」这条反直觉结论），表或几何任一改动都会挂。
	var cols := 5
	var rows := 4
	var topo := ShapeGenerator.build_iso_cubes(cols, rows)
	var poly_of := _polys_by_pos(ShapeGenerator.iso_cells_geo(cols, rows))
	var adjacency: Array = topo["adjacency"]
	assert_gt(adjacency.size(), 0, "应有邻接边")
	for e: Dictionary in adjacency:
		var a := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		var b := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
		assert_true(poly_of.has(a) and poly_of.has(b), "边的两端必须在盘内")
		assert_true(_share_edge(poly_of[a], poly_of[b]),
				"边 %s-%s 的两格不共边 —— 邻接表与几何脱节" % [str(a), str(b)])


func test_interior_degree_is_four_and_faces_of_a_cube_are_mutually_adjacent() -> void:
	var cols := 5
	var rows := 5
	var topo := ShapeGenerator.build_iso_cubes(cols, rows)
	var deg := _degree_map(topo)
	# 内部方块的三面（同方块）两两互邻
	for j in range(1, rows - 1):
		for i in range(1, cols - 1):
			for f in 3:
				var pos := Vector2i(i * 3 + f, j)
				var want: Array = []
				for g in 3:
					if g != f:
						want.append(Vector2i(i * 3 + g, j))
				for w: Vector2i in want:
					assert_true(deg[pos].has(w), "同方块的另两面必须互邻：%s → %s" % [str(pos), str(w)])
				assert_eq(deg[pos].size(), 4, "内部格度 = 4（两面同方块 + 两个跨方块异朝向面）")


func test_no_gaps_and_no_overlaps_between_adjacent_tiles() -> void:
	## 连通视觉契约（2026-09-21）：相邻格之间不得有可见空隙。
	## 本族是密铺，这条由构造保证 —— 这里按契约口径复算一遍钉死。
	var cols := 4
	var rows := 4
	var topo := ShapeGenerator.build_iso_cubes(cols, rows)
	var poly_of := _polys_by_pos(ShapeGenerator.iso_cells_geo(cols, rows))
	for e: Dictionary in topo["adjacency"]:
		var a := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		var b := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
		assert_almost_eq(_poly_gap(poly_of[a], poly_of[b]), 0.0, EPS,
				"%s-%s 之间有缝（密铺被破坏）" % [str(a), str(b)])


func test_to_adjacency_grid_registers_the_style() -> void:
	var grid := ShapeGenerator.to_adjacency_grid("iso_cubes", {"cols": 3, "rows": 3})
	assert_not_null(grid, "iso_cubes 应能建成 AdjacencyGrid")
	assert_eq(grid.style, "iso_cubes", "风格必须落到 grid.style（渲染/落盘都从它取）")
	assert_eq(grid.all_positions().size(), 27, "3×3 方块 = 27 格")


func test_holes_echo_back_into_params() -> void:
	var topo := ShapeGenerator.build_iso_cubes(3, 3, [Vector2i(2, 1), Vector2i(0, 0)])
	var holes: Array = (topo["params"] as Dictionary)["holes"]
	assert_eq(holes.size(), 2, "两个洞应回写 params")
	assert_eq(Vector2i(int(holes[0]["x"]), int(holes[0]["y"])), Vector2i(0, 0), "回写按字典序")
	assert_eq(Vector2i(int(holes[1]["x"]), int(holes[1]["y"])), Vector2i(2, 1), "回写按字典序")


func test_invalid_dims_return_empty_topology() -> void:
	# 与 build_holed_grid 同口径：返回明确的空拓扑字典 + 报错，而不是静默产半成品。
	assert_eq(ShapeGenerator.build_iso_cubes(0, 3), {"positions": [], "adjacency": []},
			"cols=0 → 空拓扑")
	assert_push_error("cols/rows 必须为正整数")
	assert_eq(ShapeGenerator.build_iso_cubes(3, -1), {"positions": [], "adjacency": []},
			"rows<0 → 空拓扑")
	assert_push_error("cols/rows 必须为正整数")


func test_out_of_range_hole_is_skipped_but_board_survives() -> void:
	# 洞是逐格数据，一条坏数据不该让整盘失效；但必须报错。
	var topo := ShapeGenerator.build_iso_cubes(2, 2, [Vector2i(9, 9)])
	assert_eq((topo["positions"] as Array).size(), 12, "越界洞被跳过，其余照建")
	assert_push_error("洞坐标越界")


# ---- 工具 ----

func _polys_by_pos(geo: Array) -> Dictionary:
	var out := {}
	for rec: Dictionary in geo:
		out[rec["pos"]] = rec["poly"]
	return out


func _degree_map(topo: Dictionary) -> Dictionary:
	var deg := {}
	for p: Dictionary in topo["positions"]:
		deg[Vector2i(int(p["x"]), int(p["y"]))] = {}
	for e: Dictionary in topo["adjacency"]:
		var a := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		var b := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
		deg[a][b] = true
		deg[b][a] = true
	return deg


## 两多边形是否共用一条完整的边（端点重合，顺序无关）。
func _share_edge(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for i in a.size():
		var a1: Vector2 = a[i]
		var a2: Vector2 = a[(i + 1) % a.size()]
		for j in b.size():
			var b1: Vector2 = b[j]
			var b2: Vector2 = b[(j + 1) % b.size()]
			if _same_pt(a1, b1) and _same_pt(a2, b2):
				return true
			if _same_pt(a1, b2) and _same_pt(a2, b1):
				return true
	return false


func _same_pt(p: Vector2, q: Vector2) -> bool:
	return absf(p.x - q.x) < EPS and absf(p.y - q.y) < EPS


func _shoelace(pts: PackedVector2Array) -> float:
	var s := 0.0
	for i in pts.size():
		var p: Vector2 = pts[i]
		var q: Vector2 = pts[(i + 1) % pts.size()]
		s += p.x * q.y - q.x * p.y
	return absf(s) * 0.5


## 两多边形的最小距离（含包含判定 → 0）。
func _poly_gap(a: PackedVector2Array, b: PackedVector2Array) -> float:
	for p: Vector2 in a:
		if Geometry2D.is_point_in_polygon(p, b):
			return 0.0
	for p: Vector2 in b:
		if Geometry2D.is_point_in_polygon(p, a):
			return 0.0
	var best := INF
	for i in a.size():
		for j in b.size():
			best = minf(best, _seg_dist(a[i], a[(i + 1) % a.size()], b[j], b[(j + 1) % b.size()]))
	return best


func _seg_dist(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> float:
	var d1 := _cross(p3, p4, p1)
	var d2 := _cross(p3, p4, p2)
	var d3 := _cross(p1, p2, p3)
	var d4 := _cross(p1, p2, p4)
	if ((d1 > 0.0) != (d2 > 0.0)) and ((d3 > 0.0) != (d4 > 0.0)):
		return 0.0
	return minf(minf(_pt_seg(p1, p3, p4), _pt_seg(p2, p3, p4)),
			minf(_pt_seg(p3, p1, p2), _pt_seg(p4, p1, p2)))


func _cross(o: Vector2, a: Vector2, b: Vector2) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)


func _pt_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 <= 1e-12:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)
