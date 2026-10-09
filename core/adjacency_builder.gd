# adjacency_builder.gd —— 「用户只画多边形 → 自动推导邻接表」的异形棋盘构建器
#
# 为什么需要：board.json 的通用邻接表（{positions, adjacency}）要求作者**手写每条边**。
# 多边形稍复杂（蜂窝 / 三角网格 / 六边形与三角形混合镶嵌）就极易写错，而写错的表现
# 往往是「生成静默失败」——作者拿不到任何线索。本模块把入口降到「作者只画多边形」：
# 邻接由**共边判据**（两多边形共享一段长度 > eps 的公共边）自动推导，退化时可用中心距兜底。
#
# 为什么判据必须是共边而不是「最近格心」：混合镶嵌里不同形状的格心距不可比（大格对小格），
# 最近格心会在尖角处把点判给邻格、连出错边。共边判据与玩家眼里的「明显相邻」同源。
#
# 为什么每次构建都要报统计：判据对不对，作者只能靠「共边命中 N 对 / 兜底 M 对 / 退化 K 格」
# 这几个数字核对；默默构建等于让用户自己猜。统计同时挂在返回值（set_meta）与静态 last_stats()。
#
# 纯函数：static + RefCounted，无引擎 / UI / autoload 依赖、不做随机、可离线跑。
# 输出满足 AdjacencyGrid 契约：坐标非负化、邻接对称、无自环、all_positions() = 有格集合。
class_name AdjacencyBuilder
extends RefCounted

## 共边判定的默认长度容差（世界单位）。小于它的公共边视为点接触，不算邻接。
const EPS_DEFAULT := 0.01
## 几何能力枚举（与 RulePlugin.geometry_kind() 的返回值同语义）：
const GEO_ADJ_GENERIC := 0   ## 只用拓扑邻域 → 任意棋盘可用
const GEO_RECT_ONLY := 1     ## 依赖矩形方向 / 行列 → 异形盘不适用

## 边类型标注（board.json 的 adjacency / neighbors 条目可选带 "kind"）。
##
## 为什么需要：异形盘上平台只保证「邻接表」这一层语义——线索值由规则自己的 compute_clue_topo
## 给出，缺省退化为「拓扑邻域计数」（core/puzzle_generator.gd:504-522 与 :435-436）。
## 于是任何依赖**方向 / 对角 / 环序 / 射线 / 同色**的语义在"只有邻接表"的盘上**根本无法求值**：
## 同样的邻接表既可能是 8 邻（含对角），也可能是 4 邻（纯正交），平台无从分辨。
## 作者把边标上 kind = 显式交出这份结构信息；**未标注 ⇒ 那些算子不适用（不是不可行）**。
const EDGE_KINDS: Array[String] = ["ortho", "diag", "ring", "ray", "other"]
const EDGE_KIND_NONE := "untyped"   ## 未标注（缺 kind 字段 / kind 非法）

## 最后一次构建的判据统计（CLI 与测试读取）。
static var _last_stats: Dictionary = {}


## 最近一次构建的判据统计（深拷贝，调用方改不到内部）。
static func last_stats() -> Dictionary:
	return _last_stats.duplicate(true)


# ==================== 对外构建入口 ====================

## 多边形集合 → AdjacencyGrid。
## cells 两种输入都支持：
##   1) Dictionary { "x,y": PackedVector2Array(顶点…), ... }
##   2) Array [ { "pos": Vector2i|{x,y}, "poly": PackedVector2Array|Array }, ... ]
## 邻接判据：共边（公共边长度 > eps）；仅当 centroid_fallback > 0 时，未共边的格对
## 再按「中心距 ≤ centroid_fallback」兜底（给退化 / 极窄多边形留出口，默认关闭防误连）。
## 返回 null = 没有任何可用多边形（已 push_error）。
static func from_polygons(cells: Variant, eps: float = EPS_DEFAULT,
		centroid_fallback: float = 0.0) -> AdjacencyGrid:
	var parsed := parse_cells(cells)
	var recs: Array = parsed["recs"]
	var input_problems: Array = parsed["problems"]
	var stats := {
		"cells": recs.size(),
		"edge_pairs": 0,
		"centroid_pairs": 0,
		"degenerate_cells": 0,
		"skipped_inputs": input_problems.size(),
	}
	_last_stats = stats
	if recs.is_empty():
		push_error("AdjacencyBuilder.from_polygons: 没有任何可用多边形（cells 为空或全部非法）")
		return null

	# 坐标非负化：与 AdjacencyGrid.normalized() 同口径（CP-SAT 的 cell 索引从 0 起，负坐标越界）。
	# 只平移**格键**，多边形顶点保持作者给的世界坐标（渲染用世界坐标，与格键平移无关）。
	var min_x := 1 << 30
	var min_y := 1 << 30
	for rec in recs:
		var p: Vector2i = rec["pos"]
		min_x = mini(min_x, p.x)
		min_y = mini(min_y, p.y)
	var positions: Array = []
	for i in recs.size():
		var p2: Vector2i = recs[i]["pos"]
		var shifted := Vector2i(p2.x - min_x, p2.y - min_y)
		recs[i]["out_pos"] = shifted
		positions.append({"x": shifted.x, "y": shifted.y})

	var degenerate := {}
	for i in recs.size():
		var poly: PackedVector2Array = recs[i]["poly"]
		if poly.size() < 3 or _poly_area(poly) <= eps:
			degenerate[i] = true
			stats["degenerate_cells"] = int(stats["degenerate_cells"]) + 1
	var bboxes: Array = []
	for rec2 in recs:
		bboxes.append(_poly_bbox(rec2["poly"] as PackedVector2Array))

	var seen := {}
	var adjacency: Array = []
	for i in recs.size():
		for j in range(i + 1, recs.size()):
			var hit := false
			if not degenerate.has(i) and not degenerate.has(j):
				# 包围盒粗筛（含边界：相邻格的包围盒常常只相切）
				if not (bboxes[i] as Rect2).intersects(bboxes[j] as Rect2, true):
					continue
				if _shared_edge_len(recs[i]["poly"], recs[j]["poly"], eps) > eps:
					hit = true
					stats["edge_pairs"] = int(stats["edge_pairs"]) + 1
			if not hit and centroid_fallback > 0.0 \
					and _centroid_dist(recs[i]["poly"], recs[j]["poly"]) <= centroid_fallback:
				hit = true
				stats["centroid_pairs"] = int(stats["centroid_pairs"]) + 1
			if hit:
				_add_edge(seen, adjacency, recs[i]["out_pos"], recs[j]["out_pos"])

	var grid := AdjacencyGrid.new()
	grid.setup_from_topo({"positions": positions, "adjacency": adjacency})
	grid.set_meta("build_stats", stats.duplicate(true))
	_last_stats = stats
	print("[AdjacencyBuilder] 格 %d / 共边命中 %d 对 / 中心距兜底 %d 对 / 退化格 %d / 跳过输入 %d" % [
		int(stats["cells"]), int(stats["edge_pairs"]), int(stats["centroid_pairs"]),
		int(stats["degenerate_cells"]), int(stats["skipped_inputs"])])
	return grid


## 参数化镶嵌 → AdjacencyGrid。adjacency 一律由几何（共边）推导，不写死边表。
## kind / params：
##   "rect"          —— {"rows":R, "cols":C}：平台矩形盘 = Moore 8 邻（与
##                      ShapeGenerator.build_holed_grid 同语义）。**不用共边判据**：
##                      几何共边只会给出 4 邻，与平台矩形盘的实际邻域不符。
##   "hex"           —— {"size":N, "orientation":"pointy"|"flat"}：六边形盘（size 语义同
##                      ShapeGenerator.build_hex：边长 N ⇒ N=3 为 7 格）。orientation 只改朝向，
##                      邻接始终由共边推得。
##   "tri"           —— {"cols":C, "rows":R}：等边三角网格（复用 ShapeGenerator 的三角几何）。
##   "mixed_hex_tri" —— {"cols":C, "rows":R}：六边形 + 三角形混合镶嵌（3.6.3.6）。
##   "voronoi"     —— {"cols":C, "rows":R, "sites":S, "seed":N, ...}：(p) Voronoi 不规则镶嵌
##                      （种子驱动的平面划分；同样只用几何，邻接由共边推得）。
## 形状为空 / 参数非法 / kind 未注册 → push_error + 返回 null。
static func from_tiling(kind: String, params: Dictionary) -> AdjacencyGrid:
	if kind == "rect":
		var topo: Dictionary = ShapeGenerator.build_holed_grid(
				int(params.get("rows", 0)), int(params.get("cols", 0)))
		if (topo["positions"] as Array).is_empty():
			push_error("AdjacencyBuilder.from_tiling: rect 参数非法（rows=%s, cols=%s）" % [
				str(params.get("rows", 0)), str(params.get("cols", 0))])
			return null
		var grid_r := AdjacencyGrid.new()
		grid_r.setup_from_topo(topo)
		grid_r.style = "custom"
		# 矩形盘的 ortho / diag 是**平台自己知道**的结构信息（Moore 8 邻的偏移表），
		# 顺手标出来：这样 board_validate 不会把它误报成「未标注方向语义」。
		var kinds_r := _infer_kinds_from_offsets(topo["adjacency"])
		grid_r.set_meta("edge_kinds", kinds_r)
		_last_stats = {"cells": grid_r.cell_count(), "edge_pairs": -1, "centroid_pairs": 0,
				"degenerate_cells": 0, "skipped_inputs": 0, "typed_edges": kinds_r.size(),
				"note": "rect 走 Moore 8 邻（非共边推导），边类型按偏移标注"}
		return grid_r

	var recs: Array = []
	var style := kind
	match kind:
		"hex":
			recs = _hex_cells(int(params.get("size", 0)), str(params.get("orientation", "pointy")))
			style = "hex"
		"tri":
			recs = ShapeGenerator.tri_grid_cells_geo(
					int(params.get("cols", 0)), int(params.get("rows", 0)))
			style = "tri_grid"
		"voronoi":
			# (p) Voronoi 不规则镶嵌：几何复用 ShapeGenerator（同一批种子 / 波前进 / 轮廓原语），
			# 邻接**不取它的边表**，而是把几何喂给 from_polygons 由共边重推 —— 这正是「用户自建棋盘」的同一路径。
			var vc := int(params.get("cols", 0))
			var vr := int(params.get("rows", 0))
			recs = ShapeGenerator.voronoi_cells_geo(vc, vr,
					ShapeGenerator.voronoi_seeds_of_params(vc, vr, params))
			style = "voronoi"
		"mixed_hex_tri":
			# 3.6.3.6：蜂窝顶点长出六边形、晶格三角形长出小三角。几何复用 ShapeGenerator
			# （同族已在 test_shape_generator / test_geo_levels 逐边复验），但**邻接不取它的边表**，
			# 而是把几何喂给 from_polygons 由共边重推——这正是「用户自建棋盘」的同一路径。
			recs = ShapeGenerator.trihex_cells_geo(
					int(params.get("cols", 0)), int(params.get("rows", 0)))
			style = "trihex"
		_:
			push_error("AdjacencyBuilder.from_tiling: 未注册的镶嵌 kind \"%s\"（可用：rect/hex/tri/mixed_hex_tri/voronoi）" % kind)
			return null
	if recs.is_empty():
		push_error("AdjacencyBuilder.from_tiling: %s 产出空形状（参数非法或规模为 0）" % kind)
		return null
	var grid := from_polygons(recs, EPS_DEFAULT, float(params.get("centroid_fallback", 0.0)))
	if grid == null:
		return null
	grid.style = style
	grid.style_params = params.duplicate(true)
	return grid


## 从 board.json 的字典直接建盘（board_validate / spec_check 共用）：
##   有 positions + (adjacency|neighbors) → 按声明建盘（style/params 原样透传）；
##   只有 cells（多边形）→ 走共边推导。
## 返回 null = 无法构建（已 push_error）。
static func from_topo_dict(data: Dictionary) -> AdjacencyGrid:
	# 边类型标注随盘一起搬走：AdjacencyGrid 只存拓扑，kind 挂在 meta 上（不侵入既有数据模型）。
	var kinds := edge_kinds_from_topo_dict(data)
	if data.has("positions") and (data.has("adjacency") or data.has("neighbors")):
		var grid := AdjacencyGrid.new()
		grid.setup_from_topo(data)
		if not kinds.is_empty():
			grid.set_meta("edge_kinds", kinds)
		return grid
	if data.has("cells"):
		var g2 := from_polygons(data["cells"])
		if g2 != null:
			g2.style = str(data.get("style", "custom"))
			var sp: Variant = data.get("params", {})
			g2.style_params = sp if sp is Dictionary else {}
			if not kinds.is_empty():
				g2.set_meta("edge_kinds", kinds)
		return g2
	push_error("AdjacencyBuilder.from_topo_dict: 既无 positions+adjacency，也无 cells，无法建盘")
	return null


# ==================== 边类型标注（结构信息，与邻接同等重要） ====================

## 规范无向边键（与 _add_edge / RuleFeasibility 的去重口径一致：端点按 (x,y) 字典序）。
static func edge_key(a: Vector2i, b: Vector2i) -> String:
	var lo := a
	var hi := b
	if b.x < a.x or (b.x == a.x and b.y < a.y):
		lo = b
		hi = a
	return "%d,%d|%d,%d" % [lo.x, lo.y, hi.x, hi.y]


## 从 board.json 字典提取边类型标注：{规范边键: kind}。
## 非法 kind 不入表（视为未标注）——合法性由 board_validate 单独报出，不在建盘期判死。
static func edge_kinds_from_topo_dict(data: Dictionary) -> Dictionary:
	var out := {}
	for e in (data.get("adjacency", []) as Array):
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		var a: Variant = _to_pos(d.get("a", null))
		var b: Variant = _to_pos(d.get("b", null))
		if a == null or b == null:
			continue
		var k := str(d.get("kind", ""))
		if EDGE_KINDS.has(k):
			out[edge_key(a, b)] = k
	return out


## 取拓扑自带的边类型标注（from_tiling("rect") / from_topo_dict 会写 meta；无则空）。
static func edge_kinds_of(topo: GridInterface) -> Dictionary:
	if topo == null or not topo.has_meta("edge_kinds"):
		return {}
	var m: Variant = topo.get_meta("edge_kinds")
	return m if m is Dictionary else {}


## 由格坐标偏移反推边类型（仅对「行列规整」的盘成立：Moore 8 邻的 (1,0)/(0,1) = ortho，
## (1,1)/(1,-1) = diag；其余记 other）。**不做几何猜测**，只用于平台自己的矩形盘产物。
static func _infer_kinds_from_offsets(adjacency: Array) -> Dictionary:
	var out := {}
	for e in adjacency:
		var d: Dictionary = e
		var a := Vector2i(int(d["a"]["x"]), int(d["a"]["y"]))
		var b := Vector2i(int(d["b"]["x"]), int(d["b"]["y"]))
		var dx := absi(b.x - a.x)
		var dy := absi(b.y - a.y)
		var kind := "other"
		if dx + dy == 1:
			kind = "ortho"
		elif dx == 1 and dy == 1:
			kind = "diag"
		out[edge_key(a, b)] = kind
	return out


# ==================== 契约自检（校验器复用） ====================

## 校验任意 GridInterface 是否满足 AdjacencyGrid 契约。
## 返回 {ok, problems:[...], cell_count, edge_count, degree_hist, edge_kind_hist, typed_edges, untyped_edges}
## （另附若干计数便于 CLI 展示）。
## kinds：可选 {规范边键: kind}；缺省取拓扑自带的 meta（from_tiling("rect") / from_topo_dict 写入）。
static func audit(topo: GridInterface, kinds: Dictionary = {}) -> Dictionary:
	var problems: Array[String] = []
	var positions: Array[Vector2i] = []
	var pos_set := {}
	var nonneg := true
	if topo != null:
		positions = topo.all_positions()
	for p in positions:
		pos_set[p] = true
		if p.x < 0 or p.y < 0:
			nonneg = false
	var kinds_map := kinds
	if kinds_map.is_empty():
		kinds_map = edge_kinds_of(topo)
	var edge_kind_hist := {}
	var seen_edge := {}
	var edge_count := 0
	var degree_hist := {}
	var self_loop := 0
	var dangling := 0
	var duplicate := 0
	var asymmetric := 0
	if topo != null:
		# 【2026-10-02 性能修复，语义不变】先建一次"格 → 邻居集合"的字典，再判对称性。
		# 原实现每个 (p, nb) 对都做 `topo.get_neighbors(nb).has(p)`——那是**数组线性扫描**，
		# 整体 O(格数×度²)：64x64 环绕盘实测 `validate()` 要 368 ms，也是编辑器"改邻域后一次停顿"
		# 的根因。换成哈希查表后是 O(格数×度)，**判定与计数完全一致**（同样的自环/盘外/重复/对称统计）。
		var adj_sets := {}
		for p0 in positions:
			var s0 := {}
			for nb0 in topo.get_neighbors(p0):
				s0[nb0] = true
			adj_sets[p0] = s0
		# 位置 → 整数 id：边去重键从**字符串**换成整数。原实现每条边都要
		# `"%d,%d|%d,%d"` 格式化一次（64x64 环绕盘 16384 条边 ⇒ 建了 16384 个字符串），
		# 这是审计里仅次于邻居遍历的开销。整数键的语义与字符串键完全等价（同样收敛无向边）。
		var pos_id := {}
		for p1 in positions:
			pos_id[p1] = pos_id.size()
		var id_span: int = maxi(positions.size(), 1)
		for p in positions:
			var nbrs: Array[Vector2i] = topo.get_neighbors(p)
			degree_hist[nbrs.size()] = int(degree_hist.get(nbrs.size(), 0)) + 1
			var local := {}
			var nb_set: Dictionary = adj_sets.get(p, {})
			for nb in nbrs:
				if nb == p:
					self_loop += 1
					continue
				if not pos_set.has(nb):
					dangling += 1
					continue
				if local.has(nb):
					duplicate += 1
					continue
				local[nb] = true
				var other: Dictionary = adj_sets.get(nb, {})
				if not other.has(p):
					asymmetric += 1
				var ia: int = pos_id[p]
				var ib: int = pos_id[nb]
				var ekey: int = mini(ia, ib) * id_span + maxi(ia, ib)
				if not seen_edge.has(ekey):
					seen_edge[ekey] = true
					edge_count += 1
					# 只有真的存在"边类型标注"时才去拼字符串键查表；
					# 无标注时（编辑器的常态）所有边都是 untyped —— 循环后一次性记入，
					# 结果与逐边 `kinds_map.get(..., EDGE_KIND_NONE)` **完全一致**。
					if not kinds_map.is_empty():
						var k := str(kinds_map.get(edge_key(p, nb), EDGE_KIND_NONE))
						edge_kind_hist[k] = int(edge_kind_hist.get(k, 0)) + 1
		if kinds_map.is_empty() and edge_count > 0:
			edge_kind_hist[EDGE_KIND_NONE] = edge_count
	if not nonneg:
		problems.append("存在负坐标（CP-SAT 的 cell 索引从 0 起，会越界）")
	if self_loop > 0:
		problems.append("存在自环 %d 处" % self_loop)
	if dangling > 0:
		problems.append("有 %d 条邻接指向盘外格" % dangling)
	if duplicate > 0:
		problems.append("同一格对出现重复邻接 %d 处" % duplicate)
	if asymmetric > 0:
		problems.append("邻接不对称 %d 处（a∈N(b) 但 b∉N(a)）" % asymmetric)
	if positions.is_empty():
		problems.append("盘内没有任何格（all_positions() 为空）")
	return {
		"ok": problems.is_empty(),
		"problems": problems,
		"cell_count": positions.size(),
		"edge_count": edge_count,
		"degree_hist": degree_hist,
		"edge_kind_hist": edge_kind_hist,
		"typed_edges": edge_count - int(edge_kind_hist.get(EDGE_KIND_NONE, 0)),
		"untyped_edges": int(edge_kind_hist.get(EDGE_KIND_NONE, 0)),
		"positions_nonneg": nonneg,
		"self_loop": self_loop,
		"dangling": dangling,
		"duplicate": duplicate,
		"asymmetric": asymmetric,
	}


# ==================== 输入解析 ====================

## 解析多边形集合（两种输入都支持）。返回 {recs: [{pos, poly}], problems: [String]}。
## 非法输入只记录进 problems，不中断（重复坐标丢弃后者）。
static func parse_cells(cells: Variant) -> Dictionary:
	var recs: Array = []
	var problems: Array[String] = []
	var raw: Array = []
	if cells is Dictionary:
		for key in (cells as Dictionary):
			raw.append({"pos": String(key), "poly": (cells as Dictionary)[key]})
	elif cells is Array:
		raw = cells as Array
	else:
		push_error("AdjacencyBuilder.parse_cells: cells 需为 Dictionary{\"x,y\": poly} 或 Array[{pos, poly}]（收到类型 %d）" % typeof(cells))
		return {"recs": [], "problems": problems}
	var seen_pos := {}
	for item in raw:
		if not (item is Dictionary):
			problems.append("条目不是字典：%s" % str(item))
			continue
		var d: Dictionary = item
		var pos_v: Variant = _to_pos(d.get("pos", null))
		if pos_v == null:
			problems.append("缺 / 非法 pos 字段：%s" % str(d.get("pos", null)))
			continue
		var pos: Vector2i = pos_v
		var poly := _to_poly(d.get("poly", null))
		if seen_pos.has(pos):
			problems.append("坐标重复 %s——后者已丢弃" % str(pos))
			continue
		if poly.size() < 3:
			problems.append("格 %s 顶点数 < 3（%d）——已保留为孤立格" % [str(pos), poly.size()])
		seen_pos[pos] = true
		recs.append({"pos": pos, "poly": poly})
	return {"recs": recs, "problems": problems}


static func _to_pos(v: Variant) -> Variant:
	if v is Vector2i:
		return v
	if v is Vector2:
		return Vector2i(int(round((v as Vector2).x)), int(round((v as Vector2).y)))
	if v is Dictionary and (v as Dictionary).has("x") and (v as Dictionary).has("y"):
		return Vector2i(int((v as Dictionary)["x"]), int((v as Dictionary)["y"]))
	if v is String:
		var parts := (v as String).split(",")
		if parts.size() == 2:
			return Vector2i(int(parts[0]), int(parts[1]))
	return null


static func _to_poly(v: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	if v is PackedVector2Array:
		return v
	if v is Array:
		for e in (v as Array):
			if e is Vector2:
				out.append(e)
			elif e is Array and (e as Array).size() >= 2:
				out.append(Vector2(float((e as Array)[0]), float((e as Array)[1])))
			elif e is Dictionary and (e as Dictionary).has("x") and (e as Dictionary).has("y"):
				out.append(Vector2(float((e as Dictionary)["x"]), float((e as Dictionary)["y"])))
	return out


# ==================== 几何判据 ====================

## 两多边形的最长公共边长度（0 = 无共边）。
static func _shared_edge_len(a: PackedVector2Array, b: PackedVector2Array, eps: float) -> float:
	var tol := maxf(eps, 1e-6)
	var best := 0.0
	for i in a.size():
		var p1 := a[i]
		var p2 := a[(i + 1) % a.size()]
		var d := p2 - p1
		var seg_len := d.length()
		if seg_len <= tol:
			continue
		var dir := d / seg_len
		for j in b.size():
			var q1 := b[j]
			var q2 := b[(j + 1) % b.size()]
			# 共线：b 的两个端点到 p1p2 所在直线的垂距都 ≤ tol
			if absf((q1 - p1).cross(dir)) > tol or absf((q2 - p1).cross(dir)) > tol:
				continue
			var t1 := (q1 - p1).dot(dir)
			var t2 := (q2 - p1).dot(dir)
			var lo := maxf(0.0, minf(t1, t2))
			var hi := minf(seg_len, maxf(t1, t2))
			best = maxf(best, hi - lo)
	return best


static func _centroid_dist(a: PackedVector2Array, b: PackedVector2Array) -> float:
	return _poly_centroid(a).distance_to(_poly_centroid(b))


static func _poly_centroid(poly: PackedVector2Array) -> Vector2:
	var s := Vector2.ZERO
	for v in poly:
		s += v
	return s / maxf(float(poly.size()), 1.0)


static func _poly_area(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var s := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		s += p.x * q.y - q.x * p.y
	return absf(s) * 0.5


static func _poly_bbox(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for v in poly:
		lo.x = minf(lo.x, v.x)
		lo.y = minf(lo.y, v.y)
		hi.x = maxf(hi.x, v.x)
		hi.y = maxf(hi.y, v.y)
	return Rect2(lo, hi - lo)


## 收一条无向边（端点按 (x,y) 字典序写入 a/b；自环 / 重复丢弃）。
static func _add_edge(seen: Dictionary, out: Array, a: Vector2i, b: Vector2i) -> void:
	if a == b:
		return
	var lo := a
	var hi := b
	if b.x < a.x or (b.x == a.x and b.y < a.y):
		lo = b
		hi = a
	var key := "%d,%d|%d,%d" % [lo.x, lo.y, hi.x, hi.y]
	if seen.has(key):
		return
	seen[key] = true
	out.append({"a": {"x": lo.x, "y": lo.y}, "b": {"x": hi.x, "y": hi.y}})


# ==================== 参数化镶嵌的几何 ====================

## 六边形盘的格集：沿用 ShapeGenerator.build_hex 的裁剪公式（|r + c - (size-1)| ≤ ⌊(size-1)/2⌋），
## 使 from_tiling("hex", {"size":N}) 与 ShapeGenerator.build_hex(N) **同格集**（测试可交叉验证）。
static func _hex_cells(size: int, orientation: String) -> Array:
	if size <= 0:
		push_error("AdjacencyBuilder: hex 的 size 必须为正整数（收到 %d）" % size)
		return []
	var half := floori((size - 1) / 2.0)
	var out: Array = []
	for r in size:
		for c in size:
			if absi(r + c - (size - 1)) <= half:
				out.append({"pos": Vector2i(c, r), "poly": _hex_poly(c, r, orientation)})
	return out


## 单位回路的正六边形（外接半径 1）。中心映射与 HEX6 邻居方向一致：
##   pointy（尖顶）：center = (√3·(c + r/2), 1.5·r)，顶点角 30°+60°k —— 邻居 (1,0)/(0,1)/(1,-1) 距离都是 √3。
##   flat（平顶）  ：center = (1.5·c, √3·(r + c/2))，顶点角 60°k。
static func _hex_poly(c: int, r: int, orientation: String) -> PackedVector2Array:
	var out := PackedVector2Array()
	var sq3 := sqrt(3.0)
	if orientation == "flat":
		var cx := 1.5 * float(c)
		var cy := sq3 * (float(r) + 0.5 * float(c))
		for k in 6:
			var a := deg_to_rad(60.0 * float(k))
			out.append(Vector2(cx + cos(a), cy + sin(a)))
	else:
		var cx2 := sq3 * (float(c) + 0.5 * float(r))
		var cy2 := 1.5 * float(r)
		for k in 6:
			var a2 := deg_to_rad(30.0 + 60.0 * float(k))
			out.append(Vector2(cx2 + cos(a2), cy2 + sin(a2)))
	return out
