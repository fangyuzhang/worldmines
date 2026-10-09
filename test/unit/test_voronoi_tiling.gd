# test_voronoi_tiling.gd —— (p) Voronoi 不规则镶嵌的登记自证（2026-10-09）
#
# 背景：《功能清单》§3 要求「六边形 / 三角形 / Voronoi 不规则镶嵌」三种自定义格孢；前两种早已在仓库里，
# Voronoi 一直是 docs/plans/2026-10-03-editor-feature-program.md:26 列的「必须先建子系统」。本轮落地
# `ShapeGenerator.build_voronoi`（core/shape_generator.gd 的 (p) 段）并把它接进四处：
#   ① `to_adjacency_grid`（用户入口）；② `EditorDoc.estimate_cells`（事前估算闸门）；
#   ③ `VariantGridMatrix`（变体×网格矩阵）；④ `AdjacencyBuilder.from_tiling`（自建棋盘路径）。
# 本文件把四处接线 + 几何本身全钉住：
#   A. 入口 / 落盘回显；
#   B. **铺装成立**：所有胞面积之和 恰好 = 包围盒面积（无缝无重叠）；
#   C. **邻接 = 共边**：逐对复验（两格相邻 ⇔ 共享 ≥ min_edge 长度的边界），不靠被测代码自证；
#   D. 确定性 + 种子量化 + 回显重建（同参数同产物；跨机器可复现）；
#   E. 不规则性（形状种类 > 1，不是清一色方框）；
#   F. 估算 = 真实格数（拿生产入口对拍，不自证）；
#   G. 矩阵登记（三态 / 原因文案 / 与缺格族同判）；
#   H. 非法参数一致拒绝。
extends GutTest

const M := preload("res://core/variant_grid_matrix.gd")
const EPS := 0.0001


## 覆盖：方盒 / 非方盒（两个方向）/ 少种子 / 单种子 / 种子密集 / 极端抖动。
func _cases() -> Array:
	return [
		{"cols": 12, "rows": 12, "sites": 6, "seed": 1},
		{"cols": 12, "rows": 12, "sites": 6, "seed": 2},
		{"cols": 20, "rows": 9, "sites": 8, "seed": 7},
		{"cols": 9, "rows": 20, "sites": 5, "seed": 3},
		{"cols": 24, "rows": 24, "sites": 16, "seed": 11},
		{"cols": 8, "rows": 8, "sites": 1, "seed": 1},
		{"cols": 15, "rows": 15, "sites": 30, "seed": 5},
		{"cols": 16, "rows": 12, "sites": 12, "seed": 1, "jitter": 0.0},
		{"cols": 16, "rows": 12, "sites": 12, "seed": 1, "jitter": 0.9},
	]


# ==================== 工具 ====================

func _geo_of(c: Dictionary) -> Array:
	var cols := int(c["cols"])
	var rows := int(c["rows"])
	return ShapeGenerator.voronoi_cells_geo(cols, rows,
			ShapeGenerator.voronoi_seeds_of_params(cols, rows, c))


func _polys(geo: Array) -> Dictionary:
	var out := {}
	for rec: Dictionary in geo:
		out[rec["pos"]] = rec["poly"]
	return out


func _pos_list(geo: Array) -> Array:
	var out: Array = []
	for rec: Dictionary in geo:
		out.append(rec["pos"])
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	return out


func _ek(a: Vector2i, b: Vector2i) -> String:
	if b.x < a.x or (b.x == a.x and b.y < a.y):
		return "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]
	return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]


## 几何版：多边形 → 无向单位边集合（顶点恒为整点、边恒为轴对齐单位段）。
func _unit_edges(poly: PackedVector2Array) -> Dictionary:
	var out := {}
	var n := poly.size()
	for i in n:
		var a := Vector2i(roundi(poly[i].x), roundi(poly[i].y))
		var b := Vector2i(roundi(poly[(i + 1) % n].x), roundi(poly[(i + 1) % n].y))
		out[_ek(a, b)] = true
	return out


func _shared_edge_len(pa: PackedVector2Array, pb: PackedVector2Array) -> int:
	var ea := _unit_edges(pa)
	var eb := _unit_edges(pb)
	var n := 0
	for k in ea:
		if eb.has(k):
			n += 1
	return n


## 鞋带公式：矩形化整点多边形的面积 = 占用的单位方格数。
func _area(poly: PackedVector2Array) -> float:
	var s := 0.0
	var n := poly.size()
	for i in n:
		var p: Vector2 = poly[i]
		var q: Vector2 = poly[(i + 1) % n]
		s += p.x * q.y - q.x * p.y
	return absf(s) * 0.5


func _topo_edge_keys(topo: Dictionary) -> Array:
	var out: Array = []
	for e: Dictionary in (topo.get("adjacency", []) as Array):
		out.append(_ek(Vector2i(int(e["a"]["x"]), int(e["a"]["y"])),
				Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))))
	out.sort()
	return out


func _topo_positions(topo: Dictionary) -> Array:
	var out: Array = []
	for p: Dictionary in (topo.get("positions", []) as Array):
		out.append(Vector2i(int(p["x"]), int(p["y"])))
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	return out


func _grid_edge_keys(g: GridInterface) -> Array:
	var out: Array = []
	for p in g.all_positions():
		for nb in g.get_neighbors(p):
			out.append(_ek(p, nb))
	out.sort()
	return out


# ==================== A. 入口与落盘回显 ====================

func test_entry_point_registers_voronoi() -> void:
	var g := ShapeGenerator.to_adjacency_grid("voronoi", {"cols": 12, "rows": 12, "sites": 6, "seed": 1})
	assert_not_null(g, "to_adjacency_grid 必须认 voronoi（否则用户选不到）")
	assert_eq(g.style, "voronoi", "style 应贯通（渲染 / 落盘都从它取）")
	assert_eq(g.cell_count(), 6, "胞数应 = 种子数（每个种子一个胞）")
	assert_eq(int(g.style_params.get("cols", 0)), 12, "params 应回显 cols")
	assert_eq(int(g.style_params.get("rows", 0)), 12, "params 应回显 rows")
	var seeds: Array = g.style_params.get("seeds", [])
	assert_eq(seeds.size(), 6, "params 必须回显种子点（别处按它重建同一张盘）")
	for s: Variant in seeds:
		var sd: Dictionary = s
		assert_almost_eq(float(sd["x"]), ShapeGenerator.quantize_seed(float(sd["x"])), 1e-9,
				"回显的种子 x 必须已量化（1/65536）")
		assert_almost_eq(float(sd["y"]), ShapeGenerator.quantize_seed(float(sd["y"])), 1e-9,
				"回显的种子 y 必须已量化（1/65536）")


# ==================== B. 铺装成立：面积守恒 ====================

func test_cells_tile_the_bounding_box_without_gaps_or_overlaps() -> void:
	for c in _cases():
		var geo := _geo_of(c)
		var want := int(c["cols"]) * int(c["rows"])
		assert_gt(geo.size(), 0, "%s：应产出非空胞集" % str(c))
		assert_eq(geo.size(), int(c["sites"]), "%s：胞数应等于种子数" % str(c))
		var total := 0.0
		for rec: Dictionary in geo:
			var poly: PackedVector2Array = rec["poly"]
			assert_gte(poly.size(), 4, "%s：胞至少 4 个顶点" % str(c))
			# 每条边都是轴对齐的单位段（矩形化整点多边形）
			for i in poly.size():
				var p: Vector2 = poly[i]
				var q: Vector2 = poly[(i + 1) % poly.size()]
				var dx := absf(p.x - q.x)
				var dy := absf(p.y - q.y)
				assert_true((dx < EPS and absf(dy - 1.0) < EPS) or (dy < EPS and absf(dx - 1.0) < EPS),
						"%s：边 %s→%s 不是轴对齐单位段" % [str(c), str(p), str(q)])
				assert_almost_eq(p.x, roundf(p.x), EPS, "%s：顶点必须是整点" % str(c))
				assert_almost_eq(p.y, roundf(p.y), EPS, "%s：顶点必须是整点" % str(c))
			total += _area(poly)
		assert_almost_eq(total, float(want), EPS,
				"%s：所有胞面积之和必须 = 包围盒面积（无缝无重叠）：%.3f vs %d" % [str(c), total, want])


# ==================== C. 邻接 = 共边（逐对复验）====================

func test_adjacency_equals_shared_boundary_length() -> void:
	var pairs_checked := 0
	for c in _cases():
		var geo := _geo_of(c)
		var topo := ShapeGenerator.build_voronoi(int(c["cols"]), int(c["rows"]), c)
		var polys := _polys(geo)
		var adj := {}
		for k in _topo_edge_keys(topo):
			adj[k] = true
		var keys := _pos_list(geo)
		for i in keys.size():
			for j in range(i + 1, keys.size()):
				var ka: Vector2i = keys[i]
				var kb: Vector2i = keys[j]
				var se := _shared_edge_len(polys[ka], polys[kb])
				var want := se >= 1
				pairs_checked += 1
				assert_eq(adj.has(_ek(ka, kb)), want,
						"%s：邻接必须 ⇔ 共边（%s-%s，共边%d）" % [str(c), str(ka), str(kb), se])
	assert_gt(pairs_checked, 0, "全部用例合计必须至少复验过一对胞（否则本用例空转）")


func test_min_edge_threshold_filters_short_shared_edges() -> void:
	var c := {"cols": 18, "rows": 18, "sites": 9, "seed": 4}
	var base := ShapeGenerator.build_voronoi(18, 18, c)
	var strict := c.duplicate(true)
	strict["min_edge"] = 3.0
	var tight := ShapeGenerator.build_voronoi(18, 18, strict)
	var base_edges := _topo_edge_keys(base)
	var tight_edges := _topo_edge_keys(tight)
	assert_gt(base_edges.size(), 0, "基准（min_edge=1）应有邻接边")
	assert_lt(tight_edges.size(), base_edges.size(),
			"min_edge=3 应剔掉短共边（%d → %d）" % [base_edges.size(), tight_edges.size()])
	for k in tight_edges:
		assert_true(base_edges.has(k), "严格档的边必须是宽松档的子集（不能新长出边）：%s" % str(k))
	assert_gt(tight_edges.size(), 0, "严格档不应把整张图拆成孤立点")


# ==================== D. 确定性 / 量化 / 回显重建 ====================

func test_same_params_give_identical_board() -> void:
	var c := {"cols": 14, "rows": 10, "sites": 7, "seed": 42}
	var a := ShapeGenerator.build_voronoi(14, 10, c)
	var b := ShapeGenerator.build_voronoi(14, 10, c)
	assert_eq(_topo_positions(a), _topo_positions(b), "同参数 ⇒ 逐格坐标相同")
	assert_eq(_topo_edge_keys(a), _topo_edge_keys(b), "同参数 ⇒ 逐边相同")
	assert_eq(a["params"], b["params"], "同参数 ⇒ 回显 params 逐字段相同")
	var c2 := c.duplicate(true)
	c2["seed"] = 43
	assert_ne(_topo_positions(ShapeGenerator.build_voronoi(14, 10, c2)), _topo_positions(a),
			"换 seed 应得到另一张盘（否则 seed 是死参数）")


func test_echoed_params_rebuild_the_same_board() -> void:
	var c := {"cols": 13, "rows": 11, "sites": 6, "seed": 9}
	var a := ShapeGenerator.build_voronoi(13, 11, c)
	var echo: Dictionary = a["params"]
	assert_true(echo.has("seeds"), "产物 params 必须带种子点（不依赖 RNG 实现细节）")
	var b := ShapeGenerator.build_voronoi(13, 11, echo)
	assert_eq(_topo_positions(a), _topo_positions(b), "按回显的 seeds 重建 ⇒ 逐格相同")
	assert_eq(_topo_edge_keys(a), _topo_edge_keys(b), "按回显的 seeds 重建 ⇒ 逐边相同")
	var g := ShapeGenerator.to_adjacency_grid("voronoi", echo)
	assert_not_null(g, "回显 params 必须能直接饱入入口")
	assert_eq(g.cell_count(), a["positions"].size(), "入口重建的格数应一致")


func test_seeds_are_quantized_and_in_box() -> void:
	var seeds := ShapeGenerator.voronoi_seeds(17, 13, 5, 3, 0.9)
	assert_eq(seeds.size(), 5, "应撒出 5 个种子")
	for s: Vector2 in seeds:
		assert_almost_eq(s.x, ShapeGenerator.quantize_seed(s.x), 1e-9, "种子 x 必须已量化")
		assert_almost_eq(s.y, ShapeGenerator.quantize_seed(s.y), 1e-9, "种子 y 必须已量化")
		assert_true(s.x >= 0.0 and s.x <= 17.0, "种子 x 必须在包围盒内（收到 %.6f）" % s.x)
		assert_true(s.y >= 0.0 and s.y <= 13.0, "种子 y 必须在包围盒内（收到 %.6f）" % s.y)


# ==================== E. 不规则性 ====================

func test_cells_are_irregular_not_uniform_squares() -> void:
	var c := {"cols": 24, "rows": 24, "sites": 12, "seed": 1}
	var geo := _geo_of(c)
	var by_verts := {}
	var areas := {}
	var non_quad := 0
	for rec: Dictionary in geo:
		var poly: PackedVector2Array = rec["poly"]
		by_verts[poly.size()] = int(by_verts.get(poly.size(), 0)) + 1
		if poly.size() != 4:
			non_quad += 1
		areas[snappedf(_area(poly), 0.5)] = true
	assert_gt(by_verts.size(), 1,
			"胞的顶点数必须不止一种（不规则，不是清一色方框）：%s" % str(by_verts))
	assert_gt(non_quad, 0, "必须有非矩形胞（顶点数 != 4），否则不是不规则镶嵌")
	assert_gt(areas.size(), 1, "胞面积必须不全相同：%s" % str(areas))
	print("[voronoi] 顶点数分布=%s / 面积种类=%d" % [str(by_verts), areas.size()])


# ==================== F. 估算 = 真实格数 ====================

func test_estimate_matches_real_cell_count() -> void:
	for c in _cases():
		var g := ShapeGenerator.to_adjacency_grid("voronoi", c.duplicate(true))
		assert_not_null(g, "%s：应能建盘" % str(c))
		var real := g.all_positions().size()
		var est := EditorDoc.estimate_cells("voronoi", c.duplicate(true), 32, 32)
		assert_eq(est, real, "%s：估算必须等于真实格数（估 %d / 真 %d）" % [str(c), est, real])
	# 不退化成方阵口径
	var c2 := {"cols": 16, "rows": 16, "sites": 8, "seed": 2}
	var est2 := EditorDoc.estimate_cells("voronoi", c2, 16, 16)
	assert_eq(est2, 8, "估算应是胞数（8）而不是包围盒面积（256）")
	assert_ne(est2, 16 * 16, "不得退化为方阵估值")


# ==================== G. 矩阵登记 ====================

func test_matrix_registers_voronoi_as_irregular_family() -> void:
	assert_true(M.is_known_grid_kind("voronoi"), "矩阵必须登记 voronoi")
	assert_true(M.grid_kinds().has("voronoi"), "grid_kinds() 必须含 voronoi")
	assert_true(M.IRREGULAR_KINDS.has("voronoi"), "voronoi 属不规则镶嵌族")
	assert_false(M.BBOX_SUBSET_KINDS.has("voronoi"),
			"Voronoi 铺满包围盒 ⇒ 不是缺格族（硬塞进去会把原因文案说成有洞）")
	assert_eq(M.status("classic", "voronoi"), M.OK, "classic（唯一 GENERIC）在任何族上都应 OK")
	var disabled := 0
	for id in VariantRegistry.all_codes():
		var st: String = M.status(id, "voronoi")
		assert_true([M.OK, M.DEGRADED, M.DISABLED].has(st), "%s × voronoi 三态非法：%s" % [id, st])
		if st == M.OK:
			assert_eq(M.reason(id, "voronoi"), "", "%s：OK 不应有原因文字" % id)
		else:
			disabled += 1
			assert_ne(M.reason(id, "voronoi").strip_edges(), "", "%s：非 OK 必须给可读原因" % id)
		assert_eq(M.degradations(id, "voronoi").size(), 0, "%s：当前矩阵无 DEGRADED 格" % id)
	assert_gt(disabled, 0, "必须有矩形专属变体被禁用（守护：宁禁不放）")


func test_global_rule_reason_says_irregular_not_holed() -> void:
	var reg := RuleRegistry.default()
	var seen := 0
	for id in VariantRegistry.all_codes():
		var rule: Object = reg.resolve(StringName(id))
		if rule == null:
			continue
		if str(rule.call("get_kind")) != RulePlugin.KIND_GLOBAL:
			continue
		if M.status(id, "voronoi") != M.DISABLED:
			continue
		seen += 1
		var r := M.reason(id, "voronoi")
		assert_true(r.contains("不规则镶嵌"),
				"%s：全局约束型在 Voronoi 上的原因必须点出「不规则镶嵌」（而不是缺格）：%s" % [id, r])
		assert_false(r.contains("缺格"),
				"%s：Voronoi 铺满包围盒，不得用「缺格」措辞：%s" % [id, r])
	assert_gt(seen, 0, "应存在被禁用的全局约束型，否则本用例空转")


# ==================== H. AdjacencyBuilder 与非法参数 ====================

func test_adjacency_builder_from_tiling_matches_generator() -> void:
	var p := {"cols": 12, "rows": 12, "sites": 6, "seed": 1}
	var g := AdjacencyBuilder.from_tiling("voronoi", p)
	assert_not_null(g, "from_tiling 必须认 voronoi")
	assert_eq(g.style, "voronoi", "style 应转成 voronoi")
	assert_eq(g.cell_count(), 6, "格数应 = 种子数")
	var g2 := ShapeGenerator.to_adjacency_grid("voronoi", p)
	# from_polygons 会把格键平移成非负（与 AdjacencyGrid.normalized 同口径，见 core/adjacency_builder.gd:70），
	# 而 build_from_cells 保留种子原位 —— 两条路径只是**坐标原点**不同，拓扑必须一致。先归一化再比图。
	var ng := AdjacencyGrid.normalized(g)
	var ng2 := AdjacencyGrid.normalized(g2)
	assert_eq(ng.cell_count(), ng2.cell_count(), "归一化后格数必须一致")
	assert_eq(_grid_edge_keys(ng), _grid_edge_keys(ng2),
			"两条路径（共边重推 / 共顶点判据）归一化后必须得到同一张图")


func test_invalid_params_are_rejected_consistently() -> void:
	var bad := [
		["cols=0", {"cols": 0, "rows": 8, "sites": 3}],
		["rows<0", {"cols": 8, "rows": -1, "sites": 3}],
		["无种子", {"cols": 8, "rows": 8}],
		["sites<0", {"cols": 8, "rows": 8, "sites": -2}],
		["min_edge<0", {"cols": 8, "rows": 8, "sites": 3, "min_edge": -1.0}],
		["seeds 元素非法", {"cols": 8, "rows": 8, "seeds": [{"x": 1.0}]}],
		["seeds 超密", {"cols": 2, "rows": 2, "sites": 9}],
	]
	for c in bad:
		var label := str(c[0])
		var params: Dictionary = c[1]
		assert_null(ShapeGenerator.to_adjacency_grid("voronoi", params),
				"%s：非法参数应返回 null（不产半成品）" % label)
		var topo := ShapeGenerator.build_voronoi(int(params.get("cols", 0)), int(params.get("rows", 0)), params)
		assert_true((topo.get("positions", []) as Array).is_empty(),
				"%s：build_voronoi 也应拒绝并返回空格集" % label)
		assert_ne(str(topo.get("error", "")).strip_edges(), "",
				"%s：拒绝必须带可读原因（error 字段）" % label)
	# 估算与生成器同向：非法 ⇒ 估算 0
	assert_eq(EditorDoc.estimate_cells("voronoi", {"cols": 0, "rows": 8, "sites": 3}, 8, 8), 0,
			"非法参数在估算层必须为 0（不退化为方阵估值）")
	assert_eq(EditorDoc.estimate_cells("voronoi", {"cols": 8, "rows": 8}, 8, 8), 0,
			"缺种子应估出 0 格（与生成器一致）")
