extends SceneTree

# board_validate.gd —— 用户自建棋盘（board.json）的自助校验 CLI（**只读**）
#
# 为什么独立成工具：异形棋盘写错了不会崩，只会「生成永远返回空」。作者需要一份
# 机器可读的体检报告（格数 / 度分布 / 对称性 / 连通分量 / 多边形重叠 / 坐标非负），
# 而不是靠肉眼数边。最后一行 `__BOARD_VERDICT__ OK|WARN|FAIL <原因>` 供脚本抓取。
#
# 用法：
#   godot --headless --path . -s res://tools/board_validate.gd -- \
#       --board=<路径或 user://…> [--cells-expected=N]
#
# 退出码：0 = OK/WARN；1 = FAIL。
# 判读：不连通盘（分量数 > 1）必然让「序贯可解」失败 ⇒ 直接 FAIL，别拿去生成。
#
# 退出必须走 CliShutdown（见 tools/cli_shutdown.gd:3-18）：直写 quit() 在 Godot 4.7.2 mono
# 下约 7/8 概率挂住，本工具会被批量脚本调用，不能赌概率。
const CliShutdown := preload("res://tools/cli_shutdown.gd")
const POLY_EPS := 0.01

var _problems: Array[String] = []
var _warnings: Array[String] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var board_path := ""
	var cells_expected := -1
	for a in args:
		var s := str(a)
		if s.begins_with("--board="):
			board_path = s.substr("--board=".length())
		elif s.begins_with("--cells-expected="):
			cells_expected = int(s.substr("--cells-expected=".length()))
	if board_path == "":
		print("用法: board_validate.gd -- --board=<路径或 user://…> [--cells-expected=N]")
		print("__BOARD_VERDICT__ FAIL 缺少 --board 参数")
		CliShutdown.request_exit(1)
		return

	print("=== board 校验: %s ===" % board_path)
	var data_v: Variant = _read_json(board_path)
	if not (data_v is Dictionary):
		_fail("无法读取或解析 JSON（%s）" % board_path)
		_finish()
		return
	var data: Dictionary = data_v

	# ---- 拓扑 ----
	var declared_positions: Array = data.get("positions", [])
	if declared_positions.is_empty() and not data.has("cells"):
		_fail("既无 positions 也无 cells：不是合法棋盘")
		_finish()
		return
	if not declared_positions.is_empty() and not (data.has("adjacency") or data.has("neighbors")):
		_fail("有 positions 但缺 adjacency / neighbors（没有邻接表就不是棋盘拓扑）")
		_finish()
		return

	# 边类型标注（结构信息）：adjacency / neighbors 条目可带 "kind"（见 §13.1）。
	var kinds := AdjacencyBuilder.edge_kinds_from_topo_dict(data)
	var grid := AdjacencyBuilder.from_topo_dict(data)
	if grid == null:
		_fail("拓扑构建失败（见上方 error）")
		_finish()
		return
	var audit := AdjacencyBuilder.audit(grid, kinds)
	print("  格数: %d    无向边数: %d" % [int(audit["cell_count"]), int(audit["edge_count"])])
	print("  度分布: %s" % _hist_text(audit["degree_hist"]))
	print("  边类型标注: %s（未标注 %d 条）" % [
		_kind_hist_text(audit["edge_kind_hist"]), int(audit["untyped_edges"])])
	print("  坐标非负: %s    自环: %d    盘外邻格: %d    重复邻接: %d    不对称: %d" % [
		"是" if bool(audit["positions_nonneg"]) else "否（FAIL）",
		int(audit["self_loop"]), int(audit["dangling"]),
		int(audit["duplicate"]), int(audit["asymmetric"])])
	for p in (audit["problems"] as Array):
		_problems.append(str(p))
	_check_edge_kinds(data, audit)

	# ---- 连通性 ----
	var comps := _components(grid)
	print("  连通分量: %d 个%s" % [comps.size(), "" if comps.size() <= 1 else "（大小 %s）" % str(comps)])
	if comps.size() > 1:
		_problems.append("盘面不连通（%d 个分量）——序贯可解必然失败，生成器只会一直返回空" % comps.size())

	# ---- 格数期望 ----
	if cells_expected >= 0 and cells_expected != int(audit["cell_count"]):
		_problems.append("格数 %d ≠ --cells-expected=%d" % [int(audit["cell_count"]), cells_expected])

	# ---- 几何（可选 cells）----
	if data.has("cells"):
		_check_geometry(data, grid, audit)
	else:
		_warnings.append("无 cells 多边形：只能校验邻接表，几何（重叠 / 退化 / bbox）未检查")

	# ---- 展示字段一致性 ----
	_check_display_fields(data, audit)

	print("=== 结论 ===")
	for w in _warnings:
		print("  [WARN] %s" % w)
	for p in _problems:
		print("  [FAIL] %s" % p)
	_finish()


## 边类型标注的结论。口径依据：异形盘上平台只保证「邻接表」这一层语义，线索值缺省退化为
## 拓扑邻域计数（core/puzzle_generator.gd:504-522），所以方向 / 对角 / 环序 / 射线 / 同色类
## 语义在「只有邻接、没有 kind」的盘上**无法求值**——那是**不适用**，绝不是**不可行**。
## 因此这里只发 WARN（盘本身完好、classic 照常可用），不 FAIL。
func _check_edge_kinds(data: Dictionary, audit: Dictionary) -> void:
	var edge_count := int(audit["edge_count"])
	if edge_count == 0:
		return
	var untyped := int(audit["untyped_edges"])
	var legal := {}
	for k in AdjacencyBuilder.EDGE_KINDS:
		legal[str(k)] = true
	var illegal := 0
	for e in (data.get("adjacency", []) as Array):
		if not (e is Dictionary):
			continue
		var kv := str((e as Dictionary).get("kind", ""))
		if kv != "" and not legal.has(kv):
			illegal += 1
	if illegal > 0:
		_warnings.append("有 %d 条边的 kind 非法（允许 %s）——非法值会被当成「未标注」：不报错，但也解锁不了语义" % [
			illegal, _join_strs(AdjacencyBuilder.EDGE_KINDS)])
	if untyped == 0:
		print("  -> 全部边已标注类型：方向 / 对角 / 环序类算子具备求值前提")
		return
	_warnings.append("有 %d/%d 条边未标注类型 ⇒ 依赖方向/对角/环序语义的算子在此盘上**不可用（不是不可行，是不适用）**；邻域计数型（classic / 规格 refs=\"topo\"）不受影响。要解锁请在 adjacency 条目加 \"kind\":\"ortho|diag|ring|ray|other\"" % [
		untyped, edge_count])


func _check_geometry(data: Dictionary, grid, audit: Dictionary) -> void:
	var parsed := AdjacencyBuilder.parse_cells(data["cells"])
	var recs: Array = parsed["recs"]
	for p in (parsed["problems"] as Array):
		_warnings.append(str(p))
	var degenerate := 0
	var polys: Array = []
	for rec in recs:
		var poly: PackedVector2Array = rec["poly"]
		polys.append(poly)
		if poly.size() < 3 or _poly_area(poly) <= POLY_EPS:
			degenerate += 1
	var overlap := 0
	for i in polys.size():
		for j in range(i + 1, polys.size()):
			if _polys_overlap(polys[i], polys[j]):
				overlap += 1
	print("  几何: 多边形 %d 个；面积≈0 / 顶点<3 的退化格 %d；重叠格对 %d" % [
		polys.size(), degenerate, overlap])
	if degenerate > 0:
		_problems.append("有 %d 个退化多边形（面积≈0 或顶点 < 3）：共边判据推不出邻接，该格会成为孤岛" % degenerate)
	if overlap > 0:
		_problems.append("有 %d 对多边形重叠：渲染会互相盖住、命中测试也会打架" % overlap)
	# 声明邻接 vs 几何共边推导：不一致只算 WARN（Moore 8 邻这类「共顶点」语义是合法的作者选择）
	if data.has("adjacency") or data.has("neighbors"):
		var derived := AdjacencyBuilder.from_polygons(data["cells"])
		if derived != null:
			var d_edges := _edge_set_of(derived)
			var declared := _edge_set_from_declared(data)
			if d_edges.size() != declared.size() or not _sets_equal(derived, grid):
				_warnings.append("声明邻接（%d 边）与几何共边推导（%d 边）不一致——若你的规则是共顶点 / 8 邻语义属正常，否则请核对" % [
					declared.size(), d_edges.size()])


func _check_display_fields(data: Dictionary, audit: Dictionary) -> void:
	# bbox：声明值 vs 实测（有 cells 用多边形顶点，否则用格键包围盒）
	var bbox_declared: Variant = data.get("bbox", null)
	if bbox_declared is Array and (bbox_declared as Array).size() == 4:
		var b := bbox_declared as Array
		var measured := _measured_bbox(data)
		var same := absf(float(b[0]) - measured[0]) <= POLY_EPS and absf(float(b[1]) - measured[1]) <= POLY_EPS \
				and absf(float(b[2]) - measured[2]) <= POLY_EPS and absf(float(b[3]) - measured[3]) <= POLY_EPS
		print("  bbox: 声明 %s / 实测 [%.3f,%.3f,%.3f,%.3f] -> %s" % [
			str(b), measured[0], measured[1], measured[2], measured[3], "一致" if same else "不一致"])
		if not same:
			_warnings.append("bbox 与实测不一致：展示尺寸会与真实盘面错位")
	# style/params 展示一致性：hex 的 params.size 能反算格数
	var style := str(data.get("style", "custom"))
	var params: Dictionary = data.get("params", {}) if data.get("params", {}) is Dictionary else {}
	if style == "hex" and params.has("size"):
		var expect := ShapeGenerator.build_hex(int(params["size"]))
		var n := (expect["positions"] as Array).size()
		if n != int(audit["cell_count"]):
			_warnings.append("style=hex / params.size=%d 反算应 %d 格，实测 %d 格——展示字段与拓扑脱节" % [
				int(params["size"]), n, int(audit["cell_count"])])
	print("  展示字段: style=%s params=%s" % [style, str(params)])


# ==================== 工具 ====================

func _finish() -> void:
	var verdict := "OK"
	var reason := "结构完整、可直接用于生成"
	if not _warnings.is_empty() and _problems.is_empty():
		verdict = "WARN"
		reason = _warnings[0]
	if not _problems.is_empty():
		verdict = "FAIL"
		reason = _problems[0]
	print("__BOARD_VERDICT__ %s %s" % [verdict, reason])
	CliShutdown.request_exit(0 if verdict != "FAIL" else 1)


func _fail(reason: String) -> void:
	_problems.append(reason)


func _read_json(path: String) -> Variant:
	var p := path
	if not p.begins_with("res://") and not p.begins_with("user://") and not p.is_absolute_path():
		p = "res://" + p
	if not FileAccess.file_exists(p):
		return null
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return JSON.parse_string(text)


func _hist_text(hist: Dictionary) -> String:
	var keys: Array = hist.keys()
	keys.sort()
	var parts: Array = []
	for k in keys:
		parts.append("%d 度:%d 格" % [int(k), int(hist[k])])
	return " ".join(parts) if not parts.is_empty() else "（无）"


## 边类型直方图（键是字符串，不能用 _hist_text 的「度」格式）。
func _kind_hist_text(hist: Dictionary) -> String:
	var keys: Array = hist.keys()
	keys.sort()
	var parts: Array = []
	for k in keys:
		parts.append("%s:%d" % [str(k), int(hist[k])])
	return " ".join(parts) if not parts.is_empty() else "（无）"


func _join_strs(arr: Array) -> String:
	var parts: Array = []
	for s in arr:
		parts.append(str(s))
	return "/".join(parts)


## 邻接表 → 连通分量（每个分量 = 格数），按大小降序。
func _components(grid: GridInterface) -> Array:
	var visited := {}
	var out: Array = []
	for p in grid.all_positions():
		if visited.has(p):
			continue
		var size := 0
		var queue: Array[Vector2i] = [p]
		visited[p] = true
		while not queue.is_empty():
			var cur: Vector2i = queue.pop_back()
			size += 1
			for nb in grid.get_neighbors(cur):
				if not visited.has(nb):
					visited[nb] = true
					queue.append(nb)
		out.append(size)
	out.sort()
	out.reverse()
	return out


## 声明邻接的规范无向边集合（按 "x,y|x,y" 键）。
func _edge_set_from_declared(data: Dictionary) -> Dictionary:
	var out := {}
	for e in (data.get("adjacency", []) as Array):
		if not (e is Dictionary):
			continue
		var a: Variant = _pos_of((e as Dictionary).get("a", null))
		var b: Variant = _pos_of((e as Dictionary).get("b", null))
		if a == null or b == null:
			continue
		out[_ekey(a, b)] = true
	if data.has("neighbors"):
		for k in (data["neighbors"] as Dictionary):
			var a2: Variant = _pos_of(k)
			if a2 == null:
				continue
			for nk in ((data["neighbors"] as Dictionary)[k] as Array):
				var b2: Variant = _pos_of(nk)
				if b2 != null:
					out[_ekey(a2, b2)] = true
	return out


func _edge_set_of(grid: GridInterface) -> Dictionary:
	var out := {}
	for p in grid.all_positions():
		for nb in grid.get_neighbors(p):
			out[_ekey(p, nb)] = true
	return out


func _sets_equal(a: GridInterface, b: GridInterface) -> bool:
	var ea := _edge_set_of(a)
	var eb := _edge_set_of(b)
	if ea.size() != eb.size():
		return false
	for k in ea:
		if not eb.has(k):
			return false
	return true


func _pos_of(v: Variant) -> Variant:
	if v is Vector2i:
		return v
	if v is Dictionary and (v as Dictionary).has("x") and (v as Dictionary).has("y"):
		return Vector2i(int((v as Dictionary)["x"]), int((v as Dictionary)["y"]))
	if v is String:
		var parts := (v as String).split(",")
		if parts.size() == 2:
			return Vector2i(int(parts[0]), int(parts[1]))
	return null


func _ekey(a: Vector2i, b: Vector2i) -> String:
	var lo := a
	var hi := b
	if b.x < a.x or (b.x == a.x and b.y < a.y):
		lo = b
		hi = a
	return "%d,%d|%d,%d" % [lo.x, lo.y, hi.x, hi.y]


## 实测 bbox = [minX,minY,maxX,maxY]（有 cells 用多边形顶点，否则用格键）。
func _measured_bbox(data: Dictionary) -> Array:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	if data.has("cells"):
		var parsed := AdjacencyBuilder.parse_cells(data["cells"])
		for rec in (parsed["recs"] as Array):
			for v: Vector2 in (rec["poly"] as PackedVector2Array):
				lo.x = minf(lo.x, v.x)
				lo.y = minf(lo.y, v.y)
				hi.x = maxf(hi.x, v.x)
				hi.y = maxf(hi.y, v.y)
	else:
		for p in (data.get("positions", []) as Array):
			var q: Variant = _pos_of(p)
			if q == null:
				continue
			lo.x = minf(lo.x, float((q as Vector2i).x))
			lo.y = minf(lo.y, float((q as Vector2i).y))
			hi.x = maxf(hi.x, float((q as Vector2i).x))
			hi.y = maxf(hi.y, float((q as Vector2i).y))
	if lo.x > hi.x:
		return [0.0, 0.0, 0.0, 0.0]
	return [lo.x, lo.y, hi.x, hi.y]


static func _poly_area(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var s := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		s += p.x * q.y - q.x * p.y
	return absf(s) * 0.5


## 两多边形是否**重叠**（面积交）。共边 / 共顶点不算重叠：
## 只认「边严格相交」与「顶点严格落在对方内部」——平铺盘恰恰靠这两条被排除掉。
func _polys_overlap(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.size() < 3 or b.size() < 3:
		return false
	if not _poly_bbox(a).intersects(_poly_bbox(b), true):
		return false
	for i in a.size():
		var a1 := a[i]
		var a2 := a[(i + 1) % a.size()]
		for j in b.size():
			if _seg_cross(a1, a2, b[j], b[(j + 1) % b.size()]):
				return true
	for v in a:
		if _point_in_poly_strict(v, b):
			return true
	for v2 in b:
		if _point_in_poly_strict(v2, a):
			return true
	return false


func _poly_bbox(poly: PackedVector2Array) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for v in poly:
		lo.x = minf(lo.x, v.x)
		lo.y = minf(lo.y, v.y)
		hi.x = maxf(hi.x, v.x)
		hi.y = maxf(hi.y, v.y)
	return Rect2(lo, hi - lo)


## 线段严格相交（端点接触 / 共线重叠都不算）。
func _seg_cross(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	var tol := 1e-9
	var d1 := (p4 - p3).cross(p1 - p3)
	var d2 := (p4 - p3).cross(p2 - p3)
	var d3 := (p2 - p1).cross(p3 - p1)
	var d4 := (p2 - p1).cross(p4 - p1)
	var s1 := (d1 > tol and d2 < -tol) or (d1 < -tol and d2 > tol)
	var s2 := (d3 > tol and d4 < -tol) or (d3 < -tol and d4 > tol)
	return s1 and s2


## 点严格落在多边形内部（射线法 + 边界排除）。
func _point_in_poly_strict(p: Vector2, poly: PackedVector2Array) -> bool:
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		if _point_seg_dist(p, a, b) <= 1e-9:
			return false
	var inside := false
	var j := poly.size() - 1
	for i in poly.size():
		var pi := poly[i]
		var pj := poly[j]
		if ((pi.y > p.y) != (pj.y > p.y)) \
				and (p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i
	return inside


func _point_seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 <= 1e-18:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
