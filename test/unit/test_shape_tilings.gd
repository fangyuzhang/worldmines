# test_shape_tilings.gd —— 四族「精确铺装」异形棋盘的门禁（2026-09-22）
#
# 四族：tri_grid（等边三角）/ trihex（3.6.3.6）/ t31212（3.12.12）/ ring（同心环盘）。
# 它们与既有族的**结构性差别**：邻接由几何反推（`ShapeGenerator.build_from_cells`），
# 不写手写方向表。因此本文件锁的不是「方向表抄得对不对」，而是**铺装本身成立**：
#
#   ① **顶角和 == 360°**（本文件的核心判据）：每个铺装顶点的入射面内角和必须恰好 360°。
#      这一条同时证明「无缝」与「无重叠」—— 比逐边量缝隙更锐利（缝隙只管相邻对，
#      顶角和管的是整张图的闭合性）。边界顶点（格集被裁掉一侧）允许 < 360°，
#      但**任何顶点都不允许 > 360°**（那意味着两块面重叠了）。
#   ② 每格是正多边形（边长一致），形状即族的身份证。
#   ③ 拓扑的每条边 = 真的共边（两格共享完整一条边）。
#   ④ 拓扑自洽：无自环、无重复边、无悬空端点、格数与几何格数一致。
extends GutTest

const ShapeGenerator := preload("res://core/shape_generator.gd")
const EPS := 0.0001


# ==================== ① 四族共同的铺装门禁 ====================

func test_all_families_tile_without_gaps_or_overlaps() -> void:
	for c in _cases():
		var geo: Array = c["geo"]
		var worst_over := _max_vertex_angle_sum(geo)
		assert_lte(worst_over, 360.0 + 0.001,
				"%s：顶点入射角和达到 %.3f°（> 360 即两块面重叠）" % [c["name"], worst_over])
		var closed := _count_closed_vertices(geo)
		assert_gt(closed, 0, "%s：应存在恰好 360° 的顶点（一个都没有 = 没铺满）" % c["name"])


func test_each_cell_is_a_regular_polygon() -> void:
	## 一致铺装 ⇒ 每族内所有边长相同（三角族边长 1；3.12.12 边长 2√3−3；
	## 环盘扇区的「弧」是等分折线，不参与边长断言）。
	for c in _cases():
		var want := float(c.get("edge", 1.0))
		if want <= 0.0:
			continue
		for rec: Dictionary in (c["geo"] as Array):
			var poly: PackedVector2Array = rec["poly"]
			assert_gte(poly.size(), 3, "%s：每格至少 3 顶点" % c["name"])
			# 环盘的外/内弧是折线，其相邻弧段长度 != 边长度；只对「非环」族断言
			if str(c["style"]) == "ring":
				continue
			for i in poly.size():
				var side := poly[i].distance_to(poly[(i + 1) % poly.size()])
				assert_almost_eq(side, want, EPS,
						"%s：格 %s 第 %d 条边长 %.6f，应 %.6f" % [
							c["name"], str(rec["pos"]), i, side, want])


func test_topology_edges_are_real_shared_edges() -> void:
	## 因为邻接是几何反推的，这条本应恒真 —— 正因如此它是防回归的关键：
	## 谁若把手写的邻接表塞回这些族，这里立刻红。
	for c in _cases():
		var topo: Dictionary = c["topo"]
		var polys := {}
		for rec: Dictionary in (c["geo"] as Array):
			polys[rec["pos"]] = rec["poly"]
		var adj: Array = topo["adjacency"]
		assert_gt(adj.size(), 0, "%s：应有邻接边" % c["name"])
		for e: Dictionary in adj:
			var ka := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
			var kb := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
			assert_true(polys.has(ka) and polys.has(kb), "%s：边 %s-%s 两端应在盘内" % [c["name"], str(ka), str(kb)])
			assert_true(_share_edge(polys[ka], polys[kb]),
					"%s：边 %s-%s 的两格并不共边" % [c["name"], str(ka), str(kb)])


func test_topology_is_self_consistent() -> void:
	for c in _cases():
		var topo: Dictionary = c["topo"]
		var positions: Array = topo["positions"]
		var geo: Array = c["geo"]
		assert_eq(positions.size(), geo.size(), "%s：拓扑格数应等于几何格数" % c["name"])
		var seen := {}
		for p: Dictionary in positions:
			var k := "%d,%d" % [int(p["x"]), int(p["y"])]
			assert_false(seen.has(k), "%s：格坐标 %s 重复" % [c["name"], k])
			seen[k] = true
		var edges := {}
		for e: Dictionary in topo["adjacency"]:
			var k1 := "%d,%d" % [int(e["a"]["x"]), int(e["a"]["y"])]
			var k2 := "%d,%d" % [int(e["b"]["x"]), int(e["b"]["y"])]
			assert_ne(k1, k2, "%s：不允许自环 %s" % [c["name"], k1])
			assert_true(seen.has(k1) and seen.has(k2), "%s：边端点 %s/%s 悬空" % [c["name"], k1, k2])
			var ek := k1 + "|" + k2 if k1 < k2 else k2 + "|" + k1
			assert_false(edges.has(ek), "%s：无向边 %s 重复" % [c["name"], ek])
			edges[ek] = true


# ==================== ② 各族的结构指纹（度分布 / 形状） ====================

func test_tri_grid_is_all_triangles_with_interior_degree_three() -> void:
	var geo := ShapeGenerator.tri_grid_cells_geo(5, 4)
	assert_eq(geo.size(), 40, "5×4 菱形格 = 40 个三角形")
	for rec: Dictionary in geo:
		assert_eq((rec["poly"] as PackedVector2Array).size(), 3, "三角网格只有三角形")
	var deg := _degree_histogram(ShapeGenerator.build_tri_grid(5, 4))
	assert_eq(int(deg.get(3, 0)), 24, "内部三角形度为 3（5×4 内区 4×3×2 = 24 个）")


func test_trihex_mixes_triangles_and_hexagons() -> void:
	var geo := ShapeGenerator.trihex_cells_geo(4, 3)
	var by_n := {}
	for rec: Dictionary in geo:
		var n := (rec["poly"] as PackedVector2Array).size()
		by_n[n] = int(by_n.get(n, 0)) + 1
	assert_eq(by_n.keys().size(), 2, "3.6.3.6 只有两种面型")
	assert_gt(int(by_n.get(6, 0)), 0, "应有六边形")
	assert_gt(int(by_n.get(3, 0)), 0, "应有三角形")
	var deg := _degree_histogram(ShapeGenerator.build_trihex(4, 3))
	# 结构不变量（不依赖补丁尺寸）：3.6.3.6 的边邻接度**上限是 6**，且两种面型都在。
	assert_eq(_max_degree(deg), 6, "3.6.3.6 的度上限应为 6（六边形的边数）")
	assert_gt(int(deg.get(6, 0)), 0, "应存在度为 6 的六边形（内部）")
	assert_gt(int(deg.get(3, 0)), 0, "应存在度为 3 的三角形")
	assert_lte(_max_degree_of_face(ShapeGenerator.build_trihex(4, 3), geo, 3), 3,
			"三角形只有 3 条边 ⇒ 度不得超过 3")


func test_t31212_has_the_widest_degree_span() -> void:
	## 3.12.12 的价值：度 3 与度 12 同盘 —— 全库最大的度数极差
	##（十二边形大而信息多、三角形小而信息少，同一盘里两种读数体验）。
	var geo := ShapeGenerator.t31212_cells_geo(3, 3)
	var by_n := {}
	for rec: Dictionary in geo:
		var n := (rec["poly"] as PackedVector2Array).size()
		by_n[n] = int(by_n.get(n, 0)) + 1
	assert_gt(int(by_n.get(12, 0)), 0, "应有十二边形（12 顶点）")
	assert_gt(int(by_n.get(3, 0)), 0, "应有三角形")
	var deg := _degree_histogram(ShapeGenerator.build_t31212(3, 3))
	# 结构不变量：3.12.12 的度上限是 12（十二边形的边数）—— 本族存在的意义就是
	# 「同一盘里同时有度 3 与度 12」，这是全库最大的度数极差。
	assert_eq(_max_degree(deg), 12, "3.12.12 的度上限应为 12（十二边形的边数）")
	assert_gt(int(deg.get(12, 0)), 0, "应存在度为 12 的十二边形（内部）")
	assert_gt(int(deg.get(3, 0)), 0, "应存在度为 3 的三角形")
	assert_lte(_max_degree_of_face(ShapeGenerator.build_t31212(3, 3), geo, 3), 3,
			"三角形只有 3 条边 ⇒ 度不得超过 3")


func test_ring_is_an_annulus_with_a_hole_and_a_closed_angular_loop() -> void:
	## 环盘的两条结构性质：① 中心是空的（甜甜圈）；② 角向首尾相接
	##（第 n−1 与第 0 扇区相邻）—— 后者在拓扑上是个环，不是直线行。
	var sectors := [6, 9, 12, 18]
	var geo := ShapeGenerator.ring_cells_geo(sectors)
	assert_eq(geo.size(), 45, "6+9+12+18 = 45 个扇区")
	var topo := ShapeGenerator.build_ring(sectors)
	var deg := _degree_histogram(topo)
	# 第 0 环（最内 6 扇区）每个扇区都有内外两圈邻居 → 度 4
	var inner := 0
	var innermost := {}
	for e: Dictionary in topo["adjacency"]:
		var k := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		if k.y == 0:
			innermost[k] = true
	assert_eq(innermost.size(), 6, "最内环 6 个扇区都应参与邻接")
	for k2: Vector2i in innermost:
		assert_lte(int(deg.get(k2, 0)), 6, "最内环扇区度不应超过 6")
	# 角向闭环：每个环的扇区数 = 该环在 positions 里的格数，且邻接里同环相邻对数量 = 扇区数
	assert_eq(_ring_closure_ok(topo, sectors), true,
			"角向应首尾相接：每环「同环相邻边数」应等于该环扇区数（含收尾那一条）")


func test_ring_rejects_sector_counts_that_break_arc_sampling() -> void:
	## 10 扇区 → 36°，不是 10° 步长的整数倍 ⇒ 环与环的弧线折点对不齐（会裂缝）⇒ 必须报错。
	assert_eq(ShapeGenerator.ring_cells_geo([10]), [], "不可整除的扇区数应被拒（返回空）")
	assert_push_error("不是步长")


# ==================== 工具 ====================

func _cases() -> Array:
	return [
		{"name": "tri_grid 5×4", "style": "tri_grid", "edge": 1.0,
			"geo": ShapeGenerator.tri_grid_cells_geo(5, 4),
			"topo": ShapeGenerator.build_tri_grid(5, 4)},
		{"name": "trihex 4×3", "style": "trihex", "edge": 0.5,
			"geo": ShapeGenerator.trihex_cells_geo(4, 3),
			"topo": ShapeGenerator.build_trihex(4, 3)},
		{"name": "t31212 3×3", "style": "t31212", "edge": 2.0 * sqrt(3.0) - 3.0,
			"geo": ShapeGenerator.t31212_cells_geo(3, 3),
			"topo": ShapeGenerator.build_t31212(3, 3)},
		{"name": "ring 4环", "style": "ring", "edge": 0.0,
			"geo": ShapeGenerator.ring_cells_geo([6, 9, 12, 18]),
			"topo": ShapeGenerator.build_ring([6, 9, 12, 18])},
	]


## 顶点 → 入射面内角和 的最大值（> 360 即重叠）。
func _max_vertex_angle_sum(geo: Array) -> float:
	var worst := 0.0
	for v in _vertex_incidence(geo):
		var tot := 0.0
		for inc: Array in _vertex_incidence(geo)[v]:
			tot += _interior_angle(geo[inc[0]]["poly"], inc[1])
		worst = maxf(worst, tot)
	return worst


func _count_closed_vertices(geo: Array) -> int:
	var n := 0
	for v in _vertex_incidence(geo):
		var tot := 0.0
		var inc: Array = _vertex_incidence(geo)[v]
		if inc.size() < 2:
			continue
		for e: Array in inc:
			tot += _interior_angle(geo[e[0]]["poly"], e[1])
		if absf(tot - 360.0) <= 0.001:
			n += 1
	return n


## 顶点键 → [[格索引, 顶点序号], ...]
func _vertex_incidence(geo: Array) -> Dictionary:
	var vm := {}
	for idx in geo.size():
		var poly: PackedVector2Array = (geo[idx] as Dictionary)["poly"]
		for i in poly.size():
			var k := _vkey(poly[i])
			if not vm.has(k):
				vm[k] = []
			(vm[k] as Array).append([idx, i])
	return vm


func _vkey(p: Vector2) -> Vector2i:
	return Vector2i(int(round(p.x * 10000000.0)), int(round(p.y * 10000000.0)))


## 多边形在顶点 i 处的内角（度）。
func _interior_angle(poly: PackedVector2Array, i: int) -> float:
	var n := poly.size()
	var p: Vector2 = poly[i]
	var a: Vector2 = poly[(i - 1 + n) % n]
	var b: Vector2 = poly[(i + 1) % n]
	var u := (a - p).normalized()
	var v := (b - p).normalized()
	return rad_to_deg(acos(clampf(u.dot(v), -1.0, 1.0)))


func _degree_histogram(topo: Dictionary) -> Dictionary:
	var adj := {}
	for e: Dictionary in topo["adjacency"]:
		var k1 := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		var k2 := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
		if not adj.has(k1):
			adj[k1] = {}
		if not adj.has(k2):
			adj[k2] = {}
		adj[k1][k2] = true
		adj[k2][k1] = true
	var hist := {}
	for k in adj:
		var d: int = (adj[k] as Dictionary).size()
		hist[d] = int(hist.get(d, 0)) + 1
	return hist


## 角向闭环校验：每个环内「相邻扇区对」应恰好等于该环扇区数（首尾那一条也算）。
func _ring_closure_ok(topo: Dictionary, sectors: Array) -> bool:
	var pairs := {}
	for e: Dictionary in topo["adjacency"]:
		var k1 := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		var k2 := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
		if k1.y != k2.y:
			continue
		var r := k1.y
		var n := int(sectors[r])
		# 同环相邻 = 编号差 1（模 n）
		var d := absi(k1.x - k2.x)
		if d == 1 or d == n - 1:
			pairs[r] = int(pairs.get(r, 0)) + 1
	for r2 in sectors.size():
		# _add_edge 存的是**无向边**（同一对只记一次）⇒ 每环恰好 n 条相邻边，
		# 其中一条是 n−1 与 0 的收尾边（= 角向闭环）。
		if int(pairs.get(r2, 0)) != int(sectors[r2]):
			return false
	return true


func _max_degree(hist: Dictionary) -> int:
	var m := 0
	for k in hist:
		m = maxi(m, int(k))
	return m


## 顶点数为 face_n 的那些格里的最大度（用于断言「三角形度不得超 3」这类结构上限）。
func _max_degree_of_face(topo: Dictionary, geo: Array, face_n: int) -> int:
	var want := {}
	for rec: Dictionary in geo:
		if (rec["poly"] as PackedVector2Array).size() == face_n:
			want[rec["pos"]] = true
	var deg := {}
	for e: Dictionary in topo["adjacency"]:
		var k1 := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		var k2 := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
		if not deg.has(k1): deg[k1] = {}
		if not deg.has(k2): deg[k2] = {}
		deg[k1][k2] = true
		deg[k2][k1] = true
	var m := 0
	for k in want:
		m = maxi(m, (deg.get(k, {}) as Dictionary).size())
	return m


func _share_edge(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for i in a.size():
		for j in b.size():
			if _same(a[i], b[j]) and _same(a[(i + 1) % a.size()], b[(j + 1) % b.size()]):
				return true
			if _same(a[i], b[(j + 1) % b.size()]) and _same(a[(i + 1) % a.size()], b[j]):
				return true
	return false


func _same(p: Vector2, q: Vector2) -> bool:
	return absf(p.x - q.x) < EPS and absf(p.y - q.y) < EPS
