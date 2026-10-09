extends GutTest
## test_core_shape_geometry.gd —— core 侧形状几何补缺的门禁（2026-10-03）。
##
## 被测：`core/shape_generator.gd`（新增 (m) ngon / (n) annulus 生成器、三档栅格化精度、
## (o) 腐蚀/膨胀）、`core/editor_verify.gd`（变体 × 网格族矩阵消费）。
##
## 四条覆盖，每条都"钉住不变量"而非"看起来像"：
##   ① 生成器：正 N 边形（格数/盘内性/与同精度圆的逐格一致性/参数回写）、
##      环形 annulus（**洞内格不得被收录**、格数 < 同外半径整圆）；
##   ② 三档精度：**默认档必须与"只判格心"的旧口径逐格、逐次序完全一致**（硬红线，
##      用本文件内**独立重写**的射线法参照实现对照），且粗档 < 默认档 < 细档（防空转）；
##   ③ 边缘平滑：腐蚀/膨胀的**判界只走网格 in_board()/get_neighbors()** —— 在带洞的环形盘上
##      逐格验证"输出的每一格都在盘上"、"邻格是洞格时洞格绝不被写入"（按包围盒实现必红）；
##   ④ 矩阵消费：不支持的组合产出可读条目（结构同 EditorDoc.validate 的 issue）、
##      支持的组合零条目、无法判定的组合（自定义规则 id / 外部拓扑 / 未登记族）不臆造。
##
## 参照实现（_poly_cells_ref / _sector_cells_ref / _star_poly / _regular_poly / _bbox_ref）
## 只复刻**文档化的判据**（射线法奇偶 + 采样窗），不复用被测代码，用于证明"默认档 == 旧行为"。

const OUTER := 10
const INNER := 5
const PRECISION := 24


# ==================== 工具：独立参照实现 ====================

func _k(p: Vector2i) -> String:
	return "%d,%d" % [p.x, p.y]


func _cells(topo: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for v: Variant in (topo.get("positions", []) as Array):
		out.append(Vector2i(int(v["x"]), int(v["y"])))
	return out


func _cell_set(topo: Dictionary) -> Dictionary:
	var s := {}
	for c in _cells(topo):
		s[c] = true
	return s


func _grid_set(g: GridInterface) -> Dictionary:
	var s := {}
	for p in g.all_positions():
		s[p] = true
	return s


## 参照：射线法 / 奇偶判据（与文档口径一致；边界点按"半个开区间"处理，这正是旧实现的语义）。
func _in_poly(poly: PackedVector2Array, p: Vector2) -> bool:
	var inside := false
	var n := poly.size()
	var j := n - 1
	for i in n:
		var pi: Vector2 = poly[i]
		var pj: Vector2 = poly[j]
		if (pi.y > p.y) != (pj.y > p.y):
			var den := pj.y - pi.y
			if is_zero_approx(den):
				den = 1e-9
			if p.x < (pj.x - pi.x) * (p.y - pi.y) / den + pi.x:
				inside = not inside
		j = i
	return inside


## 参照：顶点整数扫描窗（floor/ceil ± margin）。
func _bbox_ref(verts: PackedVector2Array, margin: int) -> Rect2i:
	if verts.is_empty():
		return Rect2i(0, 0, 0, 0)
	var min_x := 1 << 30
	var min_y := 1 << 30
	var max_x := -(1 << 30)
	var max_y := -(1 << 30)
	for v: Vector2 in verts:
		min_x = mini(min_x, floori(v.x) - margin)
		min_y = mini(min_y, floori(v.y) - margin)
		max_x = maxi(max_x, ceili(v.x) + margin)
		max_y = maxi(max_y, ceili(v.y) + margin)
	return Rect2i(Vector2i(min_x, min_y), Vector2i(max_x - min_x + 1, max_y - min_y + 1))


## 参照：默认档口径（**只判格心**）的多边形栅格化。返回位置数组（次序 = 扫描次序）。
func _poly_cells_ref(poly: PackedVector2Array) -> Array:
	var box := _bbox_ref(poly, 1)
	var out: Array = []
	for y in range(box.position.y, box.end.y):
		for x in range(box.position.x, box.end.x):
			if _in_poly(poly, Vector2(float(x), float(y))):
				out.append({"x": x, "y": y})
	return out


func _regular_poly(c: Vector2, radius: float, n: int, start_deg: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in n:
		var a := deg_to_rad(start_deg + 360.0 * float(k) / float(n))
		out.append(c + Vector2(radius * cos(a), radius * sin(a)))
	return out


func _star_poly(c: Vector2, outer: float, inner_ratio: float, points: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var inner := outer * inner_ratio
	for k in points * 2:
		var r := outer if (k % 2) == 0 else inner
		var a := deg_to_rad(-90.0 + 360.0 * float(k) / float(points * 2))
		out.append(c + Vector2(r * cos(a), r * sin(a)))
	return out


## 参照：扇形的扫描窗顶点（顶点 + 弧上每 1° 采样 + 两端点）。
func _sector_scan_verts_ref(c: Vector2, radius: float, a0: float, a1: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.append(c)
	var steps := ceili(a1 - a0) + 1
	for i in steps + 1:
		var a := minf(a0 + float(i), a1)
		var rad := deg_to_rad(a)
		out.append(c + Vector2(radius * cos(rad), radius * sin(rad)))
	return out


## 参照：扇形判据（dist ≤ radius 且角度落在 [a0,a1]；顶点格恒含）。返回位置数组（扫描次序）。
func _sector_cells_ref(radius: int, a0: float, a1: float) -> Array:
	var c := Vector2(float(radius), float(radius))
	var box := _bbox_ref(_sector_scan_verts_ref(c, float(radius), a0, a1), 1)
	var out: Array = []
	for y in range(box.position.y, box.end.y):
		for x in range(box.position.x, box.end.x):
			var d := Vector2(float(x), float(y)) - c
			var d2 := d.length_squared()
			var hit := false
			if d2 <= 0.0:
				hit = true
			elif d2 <= float(radius) * float(radius):
				var ang := fposmod(rad_to_deg(atan2(d.y, d.x)), 360.0)
				hit = ang >= a0 and ang <= a1
			if hit:
				out.append({"x": x, "y": y})
	return out


## 既有族不变量：非负 / 无重复 / 端点闭合 / 邻接 = 方向表（默认 Moore 8）。
func _assert_invariants(topo: Dictionary, label: String) -> void:
	var cells := _cells(topo)
	assert_gt(cells.size(), 0, "%s：应产出格" % label)
	var set := {}
	for c in cells:
		assert_true(c.x >= 0 and c.y >= 0, "%s：坐标必须非负 %s" % [label, str(c)])
		assert_false(set.has(c), "%s：positions 不得重复 %s" % [label, str(c)])
		set[c] = true
	var seen := {}
	var adj: Array = topo.get("adjacency", [])
	for e: Variant in adj:
		var a := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		var b := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
		assert_ne(a, b, "%s：不允许自环 %s" % [label, str(a)])
		assert_true(set.has(a) and set.has(b), "%s：邻接端点必须在盘内" % label)
		assert_false(seen.has("%s|%s" % [_k(a), _k(b)]), "%s：同一无向边不得重复" % label)
		seen["%s|%s" % [_k(a), _k(b)]] = true
	var want := 0
	for a2: Vector2i in set:
		for d: Vector2i in ShapeGenerator.MOORE8:
			var b2: Vector2i = a2 + d
			if set.has(b2) and (b2.x > a2.x or (b2.x == a2.x and b2.y > a2.y)):
				want += 1
	assert_eq(adj.size(), want, "%s：邻接应恰为 Moore 8 边集" % label)


# ==================== ① (n) 环形 annulus 生成器 ====================

func test_annulus_is_a_holed_disk() -> void:
	var t := ShapeGenerator.build_annulus(OUTER, INNER, PRECISION)
	_assert_invariants(t, "annulus")
	assert_eq(str(t["style"]), "annulus", "style 应标 annulus（对应 DAG 词汇表 primitive ring=annulus）")
	assert_eq(int((t["params"] as Dictionary).get("outer_radius", -1)), OUTER, "params.outer_radius 应回写")
	assert_eq(int((t["params"] as Dictionary).get("inner_radius", -1)), INNER, "params.inner_radius 应回写")
	assert_eq(int((t["params"] as Dictionary).get("precision", -1)), PRECISION, "params.precision 应回写")
	assert_false((t["params"] as Dictionary).has("tier"), "默认档不得写 tier（既有产物 params 零变化）")
	var c := Vector2(float(OUTER), float(OUTER))
	var set := _cell_set(t)
	# 盘内性：所有格心都在外半径内（内接多边形 ⇒ ≤ 半径，留半格余量）。
	for p in _cells(t):
		assert_true((Vector2(p) - c).length() <= float(OUTER) + 0.5,
				"annulus 格 %s 到心距 %.4f 应 ≤ %d + 半格" % [str(p), (Vector2(p) - c).length(), OUTER])
	# **洞**：明显在洞内的格心（距离 ≤ 内半径 − 0.6）一个都不许被收录。
	var hole_n := 0
	for p in _cells(t):
		assert_true((Vector2(p) - c).length() > float(INNER) - 0.6,
				"洞内格 %s（心距 %.4f）绝不能被收录" % [str(p), (Vector2(p) - c).length()])
	for dy in range(-(INNER - 1), INNER):
		for dx in range(-(INNER - 1), INNER):
			var q := Vector2i(OUTER + dx, OUTER + dy)
			if (Vector2(q) - c).length() <= float(INNER) - 0.6:
				hole_n += 1
				assert_false(set.has(q), "明显在洞内的格 %s 必须缺席" % str(q))
	assert_gt(hole_n, 0, "洞内应确有可检验的整数格（否则本断言空转）")
	# 环上显然的格必须在：正上方外环中点（角 -90°，心距 8 ∈ (inner, outer)）。
	assert_true(set.has(Vector2i(OUTER, OUTER - 8)), "环上格 (10,2) 应在盘内")
	# 环形必须比同外半径整圆**少格**（洞真的挖掉了东西）。
	var disk := ShapeGenerator.build_circle(OUTER, PRECISION)
	print("[annulus] annulus(10,5,24)=%d 格 / circle(10,24)=%d 格（洞挖掉 %d 格）" % [
			_cells(t).size(), _cells(disk).size(), _cells(disk).size() - _cells(t).size()])
	assert_gt(_cells(disk).size(), _cells(t).size(),
			"annulus 格数 %d 必须 < 同外半径整圆 %d" % [_cells(t).size(), _cells(disk).size()])


func test_annulus_rejects_invalid_params() -> void:
	var cases: Array = [
		["outer=0", ShapeGenerator.build_annulus(0, 1)],
		["inner=0", ShapeGenerator.build_annulus(8, 0)],
		["inner=outer", ShapeGenerator.build_annulus(8, 8)],
		["inner>outer", ShapeGenerator.build_annulus(8, 9)],
		["precision<3", ShapeGenerator.build_annulus(8, 2, 2)],
		["bad tier", ShapeGenerator.build_annulus(8, 2, 24, "ultra")],
		["over budget", ShapeGenerator.build_annulus(150, 10)],
	]
	for c: Variant in cases:
		var label := str(c[0])
		var t: Dictionary = c[1]
		assert_eq((t.get("positions", []) as Array).size(), 0, "%s：必须拒绝（空格集）" % label)
		assert_ne(str(t.get("error", "")).strip_edges(), "", "%s：拒绝必须给可读原因" % label)


# ==================== ① (m) 正 N 边形 ngon 生成器 ====================

func test_ngon_matches_circle_at_same_precision_and_stays_in_disk() -> void:
	var t := ShapeGenerator.build_ngon(PRECISION, 6, ShapeGenerator.RASTER_DEFAULT)
	_assert_invariants(t, "ngon(24)")
	assert_eq(str(t["style"]), "ngon", "style 应标 ngon")
	assert_eq(int((t["params"] as Dictionary).get("sides", -1)), PRECISION, "params.sides 应回写")
	# 同参数下 ngon(24, 6) 与圆 build_circle(6, 24) **逐格一致**（圆就是它的极限特例）。
	var circle := ShapeGenerator.build_circle(6, PRECISION)
	assert_eq(t["positions"], circle["positions"], "ngon(24,6) 与 circle(6,24) 的 positions 应逐项一致")
	assert_eq(t["adjacency"], circle["adjacency"], "ngon(24,6) 与 circle(6,24) 的 adjacency 应逐项一致")
	# 盘内性 + 外接圆心的格必须在（凸多边形的外心恒在内部）。
	var c := Vector2(6.0, 6.0)
	for p in _cells(t):
		assert_true((Vector2(p) - c).length() <= 6.5, "ngon 格 %s 越出外接圆 + 半格" % str(p))
	assert_true(_cell_set(t).has(Vector2i(6, 6)), "外心格 (6,6) 必须在 ngon 内")
	print("[ngon] ngon(24,6)=%d 格（与 circle(6,24) 逐格一致）" % _cells(t).size())
	# 三角形 / 四边形也自洽（不同边数同口径）。
	for sides in [3, 4, 7]:
		var g := ShapeGenerator.build_ngon(sides, 8)
		_assert_invariants(g, "ngon(%d)" % sides)
		assert_true(_cell_set(g).has(Vector2i(8, 8)), "ngon(%d) 的外心格应在盘内" % sides)
	# 正四边形（-90° 起）是旋转 45° 的正方形 ⇒ 所有格满足 |dx|+|dy| ≤ 半径 + 半格。
	for p in _cells(ShapeGenerator.build_ngon(4, 8)):
		assert_true(absi(p.x - 8) + absi(p.y - 8) <= 8 + 0,
				"正四边形(半径 8)格 %s 应满足 |dx|+|dy| ≤ 8（内接菱形）" % str(p))


func test_ngon_rejects_invalid_params() -> void:
	var cases: Array = [
		["sides=2", ShapeGenerator.build_ngon(2, 8)],
		["sides=0", ShapeGenerator.build_ngon(0, 8)],
		["radius=0", ShapeGenerator.build_ngon(6, 0)],
		["bad tier", ShapeGenerator.build_ngon(6, 8, "wide")],
		["over budget", ShapeGenerator.build_ngon(6, 150)],
	]
	for c: Variant in cases:
		var label := str(c[0])
		var t: Dictionary = c[1]
		assert_eq((t.get("positions", []) as Array).size(), 0, "%s：必须拒绝（空格集）" % label)
		assert_ne(str(t.get("error", "")).strip_edges(), "", "%s：拒绝必须给可读原因" % label)


# ==================== ② 三档精度 ====================

func test_default_raster_tier_is_identical_to_legacy_behavior() -> void:
	# 硬红线：默认档 == 旧口径（只判格心、同一扫描窗、同一次序）。
	# 参照实现是本文件内独立重写的射线法 —— 不复用被测代码。
	var c6 := Vector2(6.0, 6.0)
	var c10 := Vector2(10.0, 10.0)
	var annulus_poly := _regular_poly(c10, float(OUTER), PRECISION, -90.0)
	var inner := _regular_poly(c10, float(INNER), PRECISION, -90.0)
	for idx in range(inner.size() - 1, -1, -1):
		annulus_poly.append(inner[idx])
	var cases: Array = [
		["circle(6,24)", ShapeGenerator.build_circle(6, PRECISION), _poly_cells_ref(_regular_poly(c6, 6.0, PRECISION, -90.0))],
		["circle(4,12)", ShapeGenerator.build_circle(4, 12), _poly_cells_ref(_regular_poly(Vector2(4, 4), 4.0, 12, -90.0))],
		["ngon(6,8)", ShapeGenerator.build_ngon(6, 8), _poly_cells_ref(_regular_poly(Vector2(8, 8), 8.0, 6, -90.0))],
		["annulus(10,5,24)", ShapeGenerator.build_annulus(OUTER, INNER, PRECISION), _poly_cells_ref(annulus_poly)],
	]
	for e: Variant in cases:
		var label := str(e[0])
		var topo: Dictionary = e[1]
		var want: Array = e[2]
		assert_eq(topo["positions"], want,
				"%s：默认档 positions（含次序）必须与旧口径逐项一致" % label)
	# 显式默认档与省略档必须一字不差（调用方两种写法等价）。
	assert_eq(ShapeGenerator.build_circle(6, PRECISION, ShapeGenerator.RASTER_DEFAULT)["positions"],
			ShapeGenerator.build_circle(6, PRECISION)["positions"], "显式默认档应等价于省略")
	# 既有族未变：星形 / 扇形仍走"只判格心"（同一次序）。
	assert_eq(ShapeGenerator.build_star(5, 9, 0.5)["positions"],
			_poly_cells_ref(_star_poly(Vector2(9, 9), 9.0, 0.5, 5)),
			"build_star 的 positions 应与参照实现一致（既有族零变化）")
	assert_eq(ShapeGenerator.build_sector(7, 30.0, 120.0)["positions"],
			_sector_cells_ref(7, 30.0, 120.0),
			"build_sector 的 positions 应与参照实现一致（既有族零变化）")


func test_raster_tiers_are_monotone_and_non_vacuous() -> void:
	# 防空转：粗档 < 默认档 < 细档，且三档都非空、都必是默认档的"收缩/扩张"。
	var cases: Array = [
		["circle(6,24)", 6, PRECISION, "circle"],
		["ngon(8,6)", 8, 6, "ngon"],
		["annulus(10,5,24)", OUTER, INNER, "annulus"],
	]
	for e: Variant in cases:
		var label := str(e[0])
		var a := int(e[1])
		var b := int(e[2])
		var kind := str(e[3])
		var coarse: Dictionary = _build_tiered(kind, a, b, ShapeGenerator.RASTER_COARSE)
		var mid: Dictionary = _build_tiered(kind, a, b, ShapeGenerator.RASTER_DEFAULT)
		var fine: Dictionary = _build_tiered(kind, a, b, ShapeGenerator.RASTER_FINE)
		var n_c := _cells(coarse).size()
		var n_m := _cells(mid).size()
		var n_f := _cells(fine).size()
		print("[raster-tier] %s: coarse=%d default=%d fine=%d" % [label, n_c, n_m, n_f])
		assert_gt(n_c, 0, "%s：粗档也要出格" % label)
		assert_gt(n_m, n_c, "%s：默认档格数应严格多于粗档（%d vs %d）" % [label, n_m, n_c])
		assert_gt(n_f, n_m, "%s：细档格数应严格多于默认档（%d vs %d）" % [label, n_f, n_m])
		# 包含关系：粗 ⊆ 默认 ⊆ 细（采样严格度是单调收紧/放宽的）。
		var sc := _cell_set(coarse)
		var sm := _cell_set(mid)
		var sf := _cell_set(fine)
		for p: Vector2i in sc:
			assert_true(sm.has(p), "%s：粗档格 %s 应在默认档内（采样严格度单调）" % [label, str(p)])
		for p2: Vector2i in sm:
			assert_true(sf.has(p2), "%s：默认档格 %s 应在细档内（采样严格度单调）" % [label, str(p2)])
		# 非默认档必须把档位写进 params（可审计 / 可落盘复核）。
		assert_eq(str((coarse["params"] as Dictionary).get("tier", "")), ShapeGenerator.RASTER_COARSE,
				"%s：粗档应回写 params.tier" % label)
		assert_eq(str((fine["params"] as Dictionary).get("tier", "")), ShapeGenerator.RASTER_FINE,
				"%s：细档应回写 params.tier" % label)
		assert_false((mid["params"] as Dictionary).has("tier"),
				"%s：默认档不得回写 tier（既有产物字段零变化）" % label)
	# 细档也绝不许把洞填上：环形盘的洞内格在细档下照样缺席。
	var fine_ring := ShapeGenerator.build_annulus(OUTER, INNER, PRECISION, ShapeGenerator.RASTER_FINE)
	var cc := Vector2(float(OUTER), float(OUTER))
	for p3 in _cells(fine_ring):
		assert_true((Vector2(p3) - cc).length() > float(INNER) - 0.6,
				"细档也不得收录洞内格 %s" % str(p3))


func _build_tiered(kind: String, a: int, b: int, tier: String) -> Dictionary:
	match kind:
		"circle":
			return ShapeGenerator.build_circle(a, b, tier)
		"ngon":
			return ShapeGenerator.build_ngon(a, b, tier)
		"annulus":
			return ShapeGenerator.build_annulus(a, b, PRECISION, tier)
	return {}


# ==================== ③ 边缘平滑（腐蚀 / 膨胀）====================

func _annulus_grid() -> AdjacencyGrid:
	var g := AdjacencyGrid.new()
	g.setup_from_topo(ShapeGenerator.build_annulus(OUTER, INNER, PRECISION))
	return g


func test_dilate_and_erode_never_write_offboard_cells() -> void:
	var g := _annulus_grid()
	var board := {}
	for p in g.all_positions():
		board[p] = true
	assert_gt(board.size(), 0, "前提：环形盘应有格")
	assert_false(board.has(Vector2i(OUTER, OUTER)), "前提：盘心（洞内）不是盘上格")
	# 全盘：腐蚀/膨胀都必须是**不动点**（判界问网格 ⇒ 洞不算作"缺失的邻格"）。
	var dil := ShapeGenerator.dilate_cells(board, g)
	var ero := ShapeGenerator.erode_cells(board, g)
	assert_eq(dil.size(), board.size(), "全盘膨胀不得长出盘外/洞内格")
	assert_eq(ero.size(), board.size(), "全盘腐蚀不得因洞格而缩（洞不是「缺失的邻格」）")
	# 逐格：任一单格膨胀后，输出的每一格都必须在盘上；且**邻格是洞格时洞格绝不被写入**。
	var hole_adjacent := 0
	for p3: Vector2i in board:
		var one := ShapeGenerator.dilate_cells({p3: true}, g)
		assert_true(one.has(p3), "%s：膨胀必须含自身" % str(p3))
		for q: Vector2i in one:
			assert_true(g.in_board(q), "膨胀写出了盘外/洞内格 %s（来自 %s）" % [str(q), str(p3)])
		for d: Vector2i in ShapeGenerator.MOORE8:
			var q2: Vector2i = p3 + d
			if q2.x < 0 or q2.y < 0 or q2.x > 2 * OUTER or q2.y > 2 * OUTER:
				continue
			if board.has(q2):
				continue
			hole_adjacent += 1
			assert_false(one.has(q2),
					"洞格/盘外格 %s 被膨胀写入了（来自 %s）——判界必须走 in_board()，不得按包围盒" % [str(q2), str(p3)])
	print("[morph] annulus 盘上格=%d；『几何邻格非盘上格』的检验点=%d" % [board.size(), hole_adjacent])
	assert_gt(hole_adjacent, 0, "环形盘上必须存在「几何邻格是洞格」的格，否则本断言空转")


func test_morph_ops_drop_offboard_input_and_work_on_rect_grid() -> void:
	var g := _annulus_grid()
	# 输入里的洞格 / 盘外格一律丢弃（"不存在"不是数据错误，不报错也不写入）。
	assert_eq(ShapeGenerator.dilate_cells({Vector2i(OUTER, OUTER): true}, g).size(), 0,
			"膨胀：洞内格输入应被丢弃（不写入任何格）")
	assert_eq(ShapeGenerator.erode_cells({Vector2i(OUTER, OUTER): true}, g).size(), 0,
			"腐蚀：洞内格输入应被丢弃")
	assert_eq(ShapeGenerator.dilate_cells({Vector2i(-3, -3): true}, g).size(), 0, "膨胀：负坐标输入应被丢弃")
	# 第二实现（RectGrid，8 邻 + 边界检查）：语义逐项复核，证明不依赖任何"坐标连续"假设。
	var rg := RectGrid.new()
	rg.setup(3, 3)
	var dil := ShapeGenerator.dilate_cells({Vector2i(0, 0): true}, rg)
	assert_eq(dil.size(), 4, "3x3 上 (0,0) 的 Moore 8 邻域含自身应为 4 格")
	for q: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		assert_true(dil.has(q), "膨胀应含 %s" % str(q))
	var all := {}
	for p in rg.all_positions():
		all[p] = true
	assert_eq(ShapeGenerator.erode_cells(all, rg).size(), 9, "全盘腐蚀是不动点")
	var minus_center := all.duplicate()
	minus_center.erase(Vector2i(1, 1))
	assert_eq(ShapeGenerator.erode_cells(minus_center, rg).size(), 0,
			"3x3 去掉中心：其余每格都有邻格缺失 ⇒ 全被腐蚀掉")
	assert_eq(ShapeGenerator.erode_cells({Vector2i(0, 0): true}, rg).size(), 0,
			"孤格在 3x3 上仍会被腐蚀（其邻格不在集内）")
	# 真正的孤立格（1x1 盘：盘内没有邻格）恒保留 —— 否则单格盘会被腐蚀成空盘。
	var r1 := RectGrid.new()
	r1.setup(1, 1)
	assert_eq(ShapeGenerator.erode_cells({Vector2i(0, 0): true}, r1).size(), 1,
			"1x1 盘上单格无盘内邻格 ⇒ 腐蚀空洞成立、恒保留")
	# 2x2 全盘：每格的邻格都在集内 ⇒ 腐蚀不动点。
	var r2 := RectGrid.new()
	r2.setup(2, 2)
	var a2 := {}
	for p2 in r2.all_positions():
		a2[p2] = true
	assert_eq(ShapeGenerator.erode_cells(a2, r2).size(), 4, "2x2 全盘腐蚀应是不动点")


# ==================== ④ 变体 × 网格族矩阵消费 ====================

func _hex_doc() -> EditorDoc:
	var d := EditorDoc.new(9, 9)
	d.shape_kind = "hex"
	d.shape_params = {"size": 3}
	return d


func test_unsupported_combination_yields_readable_issue() -> void:
	# 线索规则位放一个「仅矩形几何」的全局约束（mx）：在 hex 上矩阵判 DISABLED。
	var d := _hex_doc()
	d.clue_rule_id = "mx"
	var issues := EditorVerify.variant_grid_issues(d)
	assert_eq(issues.size(), 1, "mx × hex 应恰产 1 条问题（实际：%s）" % str(issues))
	if issues.size() != 1:
		return
	var it: Dictionary = issues[0]
	assert_eq(str(it["code"]), "variant_grid_disabled", "被禁条目 code 应带状态")
	assert_eq(str(it["level"]), EditorDoc.ISSUE_ERROR, "被禁应是 error 级（勾了不生效）")
	assert_eq(it["pos"], Vector2i(-1, -1), "与格无关的条目 pos 应为 (-1,-1)")
	var text := str(it["text"])
	assert_true(text.contains("mx"), "理由要点名变体：%s" % text)
	assert_true(text.contains("hex"), "理由要点名网格族：%s" % text)
	assert_gt(text.length(), 40, "理由必须可读（不能是空壳）：%s" % text)
	# 全局规则位同样被消费（线索位 classic 是 OK 的）。
	var d2 := _hex_doc()
	d2.clue_rule_id = "classic"
	d2.global_rule_ids = ["mx"]
	var issues2 := EditorVerify.variant_grid_issues(d2)
	assert_eq(issues2.size(), 1, "classic(线索) + mx(全局) × hex：只应因全局 mx 产 1 条")
	if issues2.size() == 1:
		assert_true(str(issues2[0]["text"]).contains("mx"), "理由应点名出问题的变体")


func test_supported_combinations_yield_no_issue_and_unjudgeable_ones_are_skipped() -> void:
	# 支持：classic（唯一 GENERIC）× hex ⇒ 零条目。
	var ok_doc := _hex_doc()
	ok_doc.clue_rule_id = "classic"
	assert_eq(EditorVerify.variant_grid_issues(ok_doc).size(), 0, "classic × hex 是完整支持 ⇒ 不得有条目")
	# 支持：矩形盘上 mx ⇔ OK（变体的定义域）。
	var rect := EditorDoc.new(9, 9)
	rect.clue_rule_id = "mx"
	assert_eq(EditorVerify.grid_kind_of(rect), VariantGridMatrix.RECT, "无形状/无环绕 ⇒ 网格族应为 rect")
	assert_eq(EditorVerify.variant_grid_issues(rect).size(), 0, "mx × rect 是支持组合 ⇒ 零条目")
	# 不支持：环绕矩形盘同样走邻接表 ⇒ 仅矩形几何的 mx 被禁。
	var wrap := EditorDoc.new(9, 9)
	wrap.wrap = true
	wrap.clue_rule_id = "mx"
	assert_eq(EditorVerify.grid_kind_of(wrap), VariantGridMatrix.RECT_WRAP, "环绕 ⇒ 网格族应是 rect_wrap")
	assert_eq(EditorVerify.variant_grid_issues(wrap).size(), 1, "mx × rect_wrap 应产 1 条")
	# 不臆造①：自定义规则 id（不在注册表）——矩阵对它无话可说，不得硬判"未登记变体"。
	var custom := _hex_doc()
	custom.clue_rule_id = "my_ai_spec_xxx"
	assert_eq(EditorVerify.active_variant_ids(custom).size(), 0,
			"自定义规则 id 不在注册表 ⇒ 活跃变体集合应为空")
	assert_eq(EditorVerify.variant_grid_issues(custom).size(), 0, "不臆造：自定义规则 id 不产条目")
	# 不臆造②：外部拓扑（族名不在矩阵名单里）⇒ 网格族取不到，零条目。
	var foreign := EditorDoc.new(9, 9)
	foreign.foreign_topology = {"positions": [{"x": 0, "y": 0}], "neighbors": {}}
	foreign.clue_rule_id = "mx"
	assert_eq(EditorVerify.grid_kind_of(foreign), "", "外部拓扑 ⇒ 网格族取不到（空串）")
	assert_eq(EditorVerify.variant_grid_issues(foreign).size(), 0, "不臆造：外部拓扑不产条目")
	# 不臆造③：未登记的 shape_kind ⇒ 同上。
	var unknown := EditorDoc.new(9, 9)
	unknown.shape_kind = "hyperbolic"
	unknown.clue_rule_id = "mx"
	assert_eq(EditorVerify.grid_kind_of(unknown), "", "未登记族 ⇒ 空串")
	assert_eq(EditorVerify.variant_grid_issues(unknown).size(), 0, "不臆造：未登记族不产条目")


func test_verify_merges_matrix_issues_exactly_once() -> void:
	# 一份校验不过（雷位不在 hex 盘上）的文档：验证器仍要带上矩阵消费结果，且不得重复挂两遍。
	var d := _hex_doc()
	d.mines = [Vector2i(0, 0)]     # hex(3) 的盘上格不含 (0,0) ⇒ validate 报 mine_off_board
	d.clue_rule_id = "mx"
	var r := EditorVerify.verify(d)
	assert_eq(str(r["state"]), EditorVerify.STATE_UNKNOWN, "校验不过 ⇒ 未知（不给可解/需猜结论）")
	var vg: Array = r["variant_grid_issues"]
	assert_eq(vg.size(), 1, "验证结果应带 1 条矩阵条目（实际：%s）" % str(vg))
	var n := 0
	for it: Variant in (r["issues"] as Array):
		if str((it as Dictionary).get("code", "")).begins_with("variant_grid_"):
			n += 1
	assert_eq(n, vg.size(), "矩阵条目在 issues 统一流里不得重复或缺失（幂等合并）")
	# 文档校验本身的问题也要在（不能因为挂了矩阵条目就把原有问题挤掉）。
	var has_validate_issue := false
	for it2: Variant in (r["issues"] as Array):
		if str((it2 as Dictionary).get("code", "")) == "mine_off_board":
			has_validate_issue = true
	assert_true(has_validate_issue, "原有校验问题必须仍在 issues 里")


# ==================== ⑤ to_adjacency_grid：新增 kind + 未知 kind 显式失败 ====================
#
# 【为什么单独钉这条语义分界】**shape 名 ≠ DAG 名，二者同名不同义**：
#   · `ShapeDag` 的 primitive "ring" = **annulus**（单个内圆挖空的带洞形状）→ 生成器 build_annulus；
#   · `ShapeGenerator.to_adjacency_grid` 的 kind "ring" = **同心环盘**（多格 + 角向闭环，参数
#     sectors/step_deg/r0/dr）——坐标语义是 (扇区号 k, 环号 r)，与 annulus 的整数格完全不同。
#   ⇒ 曾出现过的坑：调用方拿 DAG 的 shape 名直接喂本入口，"ring" 撞名 ⇒ **静默画出环盘**（错几何）。
#   收口 = 本入口给 annulus / ngon 各自的 kind（映射后的正确落点）+ 未知 kind 一律显式失败。


func test_to_adjacency_grid_registers_annulus_and_ngon() -> void:
	var ann := ShapeGenerator.to_adjacency_grid("annulus",
			{"outer_radius": OUTER, "inner_radius": INNER, "precision": PRECISION})
	assert_not_null(ann, "annulus 必须能被 to_adjacency_grid 解析（DAG 映射的正确落点）")
	var direct := ShapeGenerator.build_annulus(OUTER, INNER, PRECISION)
	assert_eq(ann.cell_count(), _cells(direct).size(), "annulus 入口格数应与 build_annulus 一致")
	assert_eq(_grid_set(ann), _cell_set(direct), "annulus 入口格集应与 build_annulus 逐格一致")
	assert_eq(ann.style, str(direct["style"]), "annulus：style 应贯通")
	assert_eq(ann.style_params, direct["params"], "annulus：params 应贯通")
	var ng := ShapeGenerator.to_adjacency_grid("ngon", {"sides": 6, "radius": 8})
	assert_not_null(ng, "ngon 必须能被 to_adjacency_grid 解析")
	var d2 := ShapeGenerator.build_ngon(6, 8)
	assert_eq(ng.cell_count(), _cells(d2).size(), "ngon 入口格数应与 build_ngon 一致")
	assert_eq(_grid_set(ng), _cell_set(d2), "ngon 入口格集应与 build_ngon 逐格一致")
	assert_eq(ng.style, "ngon", "ngon：style 应贯通")
	assert_eq(ng.style_params, d2["params"], "ngon：params 应贯通")
	# 三档精度档位经入口照样可传（tier 可省，缺省 default）。
	var coarse := ShapeGenerator.to_adjacency_grid("annulus",
			{"outer_radius": OUTER, "inner_radius": INNER, "precision": PRECISION, "tier": "coarse"})
	assert_not_null(coarse, "annulus 粗档应可经入口构建")
	assert_eq(str(coarse.style_params.get("tier", "")), "coarse", "入口应把 tier 透传给 build_annulus")
	assert_lt(coarse.cell_count(), ann.cell_count(), "粗档格数应少于默认档（%d < %d）" % [
			coarse.cell_count(), ann.cell_count()])
	# 非法参数仍走 build_* 的拒绝分支（返回 null，不产半成品）。
	assert_null(ShapeGenerator.to_adjacency_grid("annulus", {"outer_radius": 8, "inner_radius": 0}),
			"inner_radius=0 ⇒ 拒绝（null）")
	assert_null(ShapeGenerator.to_adjacency_grid("ngon", {"sides": 2, "radius": 8}),
			"sides=2 ⇒ 拒绝（null）")
	print("[adj-grid] annulus=%d 格（coarse=%d） / ngon(6,8)=%d 格" % [
			ann.cell_count(), coarse.cell_count(), ng.cell_count()])


func test_to_adjacency_grid_ring_is_a_dish_not_an_annulus() -> void:
	# 同一个字符串 "ring" 在两套命名空间里是两套几何 —— 必须逐项钉住"它们是不同的东西"。
	var sectors := [6, 9, 12]
	var dish := ShapeGenerator.to_adjacency_grid("ring", {"sectors": sectors})
	assert_not_null(dish, "ring kind（同心环盘）必须可用")
	assert_eq(dish.cell_count(), 27, "环盘 = 各环扇区数之和 6+9+12 = 27 格")
	# 环盘的格集**恰为** (扇区号 k, 环号 r)：与 annulus 的整数格 (x, y) 语义完全不同。
	var want_dish := {}
	for r in sectors.size():
		for k in int(sectors[r]):
			want_dish[Vector2i(k, r)] = true
	assert_eq(_grid_set(dish), want_dish, "环盘的格集应恰为 (扇区号 k, 环号 r)")
	var ann := ShapeGenerator.to_adjacency_grid("annulus",
			{"outer_radius": OUTER, "inner_radius": INNER, "precision": PRECISION})
	assert_not_null(ann, "annulus kind 必须可用")
	assert_eq(ann.cell_count(), 229, "annulus(10,5,24) = 229 格")
	assert_ne(ann.cell_count(), dish.cell_count(),
			"annulus 与环盘必须是两套几何（%d vs %d），不得撞成同一个" % [ann.cell_count(), dish.cell_count()])
	assert_false(_grid_set(ann).has(Vector2i(OUTER, OUTER)), "annulus 的盘心（洞内）不得在盘上")
	assert_false(_grid_set(dish).has(Vector2i(OUTER, OUTER)), "环盘坐标是 (扇区,环)，没有 (10,10) 这个格")


func test_to_adjacency_grid_unknown_kind_fails_loud() -> void:
	# 【前/后行为】改前改后一致：未注册 kind ⇒ push_error + null（`_:` 分支**没有**任何默认几何）。
	# 这条断言的意义是把"绝不静默兜底"钉死：将来若有人加"落到默认方阵/环盘"的分支，这里必红。
	for bad: Variant in ["", "hyperbolic", "annulus_wrap", "ngon2", "rings", "Ring", " annulus",
			"annulus ", "ANNULUS", "default", "build_annulus"]:
		assert_null(ShapeGenerator.to_adjacency_grid(str(bad), {}),
				"未注册 kind「%s」必须显式失败（null），绝不许画出另一种几何" % str(bad))
	# 已注册但参数类型错的 kind，也在入口处显式失败（既有 mask 分支），不产半成品。
	# 已登记但参数退化的 kind 同样必须显式失败：voronoi 缺 cols / rows ⇒ 拒绝（null）。
	assert_null(ShapeGenerator.to_adjacency_grid("voronoi", {}), "voronoi 缺 cols/rows ⇒ null")
	assert_null(ShapeGenerator.to_adjacency_grid("mask", {"style": "hex", "mask": "not-an-array"}),
			"mask 参数类型错误 ⇒ null")
	assert_null(ShapeGenerator.to_adjacency_grid("ring", {"sectors": [2]}),
			"环盘扇区数 < 3 ⇒ 拒绝（null）")
