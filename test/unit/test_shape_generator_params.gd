extends GutTest
## test_shape_generator_params.gd —— 参数化轮廓族（圆 / 星形 / 扇形）门禁。
##
## 被测：`core/shape_generator.gd` 的 build_circle / build_star / build_sector。
## 六条覆盖（对应任务口径）：
##   ① 圆 / 星 / 扇形在给定参数下格数与**几何自洽**：格心到圆心（星心 / 扇形顶点）的距离
##      ≤ 半径 + 半格——这就是"对拍"的判据（栅格化后不得越出解析形状外）；
##   ② 星形角数 = points：角向最大半径剖面上，半径 ≥ 0.8*外半径 的**连通角度簇**数（逐角复核）；
##   ③ 扇形只落在 [start_deg, end_deg] 内（顶点格 dist=0 角度未定义，单列）；
##   ④ 非法参数（半径 ≤ 0 / 角数 < 3 / precision < 3 / NaN / 比值越界 / 角度区间非法）
##      被拒且带可读 `error`（且不崩）；
##   ⑤ 超预算（上界 > EditorDoc.MAX_CELL_BUDGET）被拒且有可读原因；
##   ⑥ 既有族行为未变：hex / holed_grid 冒烟对照（锁定既有数学量 + 独立重算 Moore 8 边集）。
##
## 断言口径：几何量一律**独立重算**（不调用被测函数），不写"看起来像"的弱断言。
## 三族的邻接是 Moore 8 邻（与 holed_grid 同款），本文件用公开的 ShapeGenerator.MOORE8 独立重算边集对照。

const CIRCLE_R := 6
const STAR_POINTS := 5
const STAR_OUTER := 12
const SECTOR_R := 8
const SECTOR_A0 := 30.0
const SECTOR_A1 := 120.0


# ==================== 工具（独立重算，不碰被测实现） ====================

func _k(p: Vector2i) -> String:
	return "%d,%d" % [p.x, p.y]


func _center(r: int) -> Vector2:
	return Vector2(float(r), float(r))


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


func _error_of(topo: Dictionary) -> String:
	return str(topo.get("error", ""))


## 独立重算某个方向表的无向边数（规范键 = (x,y) 字典序；方向表含双向偏移 ⇒ 只数一次）。
func _dir_edge_count(cells: Dictionary, dirs: Array[Vector2i]) -> int:
	var n := 0
	for a: Vector2i in cells:
		for d: Vector2i in dirs:
			var b: Vector2i = a + d
			if cells.has(b) and (b.x > a.x or (b.x == a.x and b.y > a.y)):
				n += 1
	return n


## 共同不变量：非负 / 无重复 / 无自环 / 端点闭合 / 无重复无向边 / 邻接 = 给定方向表。
## dirs 略过（空）时按参数化轮廓族的 Moore 8 邻口径；既有族传自己的方向表（hex → HEX6）。
func _assert_outline_invariants(topo: Dictionary, label: String, dirs: Array[Vector2i] = []) -> void:
	var cells := _cells(topo)
	assert_gt(cells.size(), 0, "%s：应产出格" % label)
	var set := {}
	for c in cells:
		assert_true(c.x >= 0 and c.y >= 0,
				"%s：坐标必须非负（board.gd 直接 setup_from_topo、不做 normalized）%s" % [label, str(c)])
		assert_false(set.has(c), "%s：positions 不得有重复坐标 %s" % [label, str(c)])
		set[c] = true
	var adj: Array = topo.get("adjacency", [])
	var seen := {}
	for e: Variant in adj:
		var a := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		var b := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
		assert_ne(a, b, "%s：不允许自环 %s" % [label, str(a)])
		assert_true(set.has(a) and set.has(b), "%s：邻接端点必须在盘内（%s - %s）" % [label, str(a), str(b)])
		assert_false(seen.has("%s|%s" % [_k(a), _k(b)]), "%s：同一无向边不得重复（%s - %s）" % [label, str(a), str(b)])
		seen["%s|%s" % [_k(a), _k(b)]] = true
	var table: Array[Vector2i] = dirs if not dirs.is_empty() else ShapeGenerator.MOORE8
	assert_eq(adj.size(), _dir_edge_count(set, table), "%s：邻接应恰为该方向表的边集" % label)


## 契约：能被 AdjacencyGrid 无损消费（格数 / 边数不漂移）+ 邻接对称。
func _assert_consumable(topo: Dictionary, label: String) -> void:
	var g := AdjacencyGrid.new()
	g.setup_from_topo(topo)
	var n_cells := _cells(topo).size()
	assert_eq(g.cell_count(), n_cells, "%s：cell_count 应等于 positions 数" % label)
	var total := 0
	for p in g.all_positions():
		for nb in g.get_neighbors(p):
			assert_true(g.get_neighbors(nb).has(p), "%s：邻接不对称 %s→%s" % [label, _k(p), _k(nb)])
			total += 1
	assert_eq(total / 2, (topo.get("adjacency", []) as Array).size(),
			"%s：setup_from_topo 不得丢边或造边" % label)


## 精确圆盘格数（dist² ≤ R²）——独立实现，用于圆族"内接多边形 ⊆ 圆盘"的上界对照。
func _disk_count(R: int) -> int:
	var n := 0
	for dy in range(-R, R + 1):
		var t := R * R - dy * dy
		n += 2 * int(sqrt(float(t))) + 1
	return n


## 角向最大半径剖面：每 1° 桶取落在该桶内的格子的最大半径（无格 = 0）。
func _angular_max_profile(topo: Dictionary, c: Vector2) -> Array:
	var bins: Array = []
	bins.resize(360)
	bins.fill(0.0)
	for p in _cells(topo):
		var d := Vector2(p) - c
		var r := d.length()
		if r <= 0.0001:
			continue
		var b := int(fposmod(rad_to_deg(atan2(d.y, d.x)), 360.0)) % 360
		bins[b] = maxf(float(bins[b]), r)
	return bins


## 角数：把"半径 ≥ thresh"的桶向两侧各膨胀 W 度（格子稀疏会让同一角内出现空格桶），
## 再数环形连通簇。W 必须 < 两角之间的角度间隔、且 ≥ 格子在角向上的最大相邻间隙。
func _arm_count(profile: Array, thresh: float, W: int = 5) -> int:
	var n := profile.size()
	var high: Array = []
	high.resize(n)
	high.fill(false)
	for b in n:
		if float(profile[b]) < thresh:
			continue
		for k in range(-W, W + 1):
			high[(b + k + n) % n] = true
	var clusters := 0
	for b in n:
		if high[b] and not high[(b + n - 1) % n]:
			clusters += 1
	return clusters


# ==================== ① 圆：格数与几何自洽 ====================

func test_circle_cells_within_radius_and_count_sane() -> void:
	var t := ShapeGenerator.build_circle(CIRCLE_R, 24)
	_assert_outline_invariants(t, "circle")
	_assert_consumable(t, "circle")
	# 对拍：每个格心到圆心距离 ≤ 半径 + 半格（内接多边形 ⇒ 严格 ≤ 半径，这里留半格余量）
	for p in _cells(t):
		var d := Vector2(p) - _center(CIRCLE_R)
		assert_true(d.length() <= float(CIRCLE_R) + 0.5,
				"圆格心 %s 到心距 %.4f 必须 ≤ 半径 + 半格 %.1f" % [str(p), d.length(), CIRCLE_R + 0.5])
	# 内接多边形 ⊆ 精确圆盘 ⇒ 格数不得超过独立算出的圆盘格数；precision=24 时应接近圆盘
	var disk := _disk_count(CIRCLE_R)
	assert_true(_cells(t).size() <= disk, "内接多边形格数 %d 不得超过精确圆盘 %d" % [_cells(t).size(), disk])
	assert_true(_cells(t).size() >= int(floor(float(disk) * 0.95)),
			"precision=24 的圆格数 %d 应接近精确圆盘 %d（≥ 95%%）" % [_cells(t).size(), disk])
	# 明显在盘内的格必须在（圆心 + 四正交邻格）；明显在盘外的角格必须不在
	var set := _cell_set(t)
	for p: Vector2i in [Vector2i(CIRCLE_R, CIRCLE_R), Vector2i(CIRCLE_R + 1, CIRCLE_R),
			Vector2i(CIRCLE_R, CIRCLE_R - 1)]:
		assert_true(set.has(p), "盘内格 %s 应在圆内" % str(p))
	assert_false(set.has(Vector2i(0, 0)), "角格 (0,0) 到心距 ≈ 8.49 > 半径，不应在圆内")


func test_circle_precision_is_a_monotone_knob() -> void:
	# precision 是真实旋钮：边数越多，内接多边形越贴近圆盘 ⇒ 格数单调不减
	var coarse := ShapeGenerator.build_circle(CIRCLE_R, 6)
	var fine := ShapeGenerator.build_circle(CIRCLE_R, 48)
	assert_gt(_cells(coarse).size(), 0, "粗精度也要出格")
	assert_true(_cells(fine).size() >= _cells(coarse).size(),
			"precision 越大格数不得减少（6→%d, 48→%d）" % [_cells(coarse).size(), _cells(fine).size()])
	assert_true(int((fine["params"] as Dictionary).get("precision", -1)) == 48, "params.precision 应回写")


# ==================== ② 星形：角数 = points ====================

func test_star_has_exactly_points_arms() -> void:
	var t := ShapeGenerator.build_star(STAR_POINTS, STAR_OUTER, 0.45)
	_assert_outline_invariants(t, "star")
	_assert_consumable(t, "star")
	assert_eq(int((t["params"] as Dictionary).get("points", -1)), STAR_POINTS, "params.points 应回写角数")
	# 几何自洽：格心到星心距离 ≤ 外半径 + 半格
	for p in _cells(t):
		var d := Vector2(p) - _center(STAR_OUTER)
		assert_true(d.length() <= float(STAR_OUTER) + 0.5,
				"星形格心 %s 到心距 %.4f 必须 ≤ 外半径 + 半格 %.1f" % [str(p), d.length(), STAR_OUTER + 0.5])
	# 角数 = 角向最大半径 ≥ 0.8*外半径 的连通角度簇数
	var clusters := _arm_count(_angular_max_profile(t, _center(STAR_OUTER)), 0.8 * float(STAR_OUTER))
	assert_eq(clusters, STAR_POINTS,
			"星形角数应为 %d（角向最大半径 ≥ %.1f 的连通簇数，实际 %d）" % [
				STAR_POINTS, 0.8 * STAR_OUTER, clusters])


func test_star_inner_ratio_controls_size() -> void:
	# inner_ratio 是真实旋钮：比越大星越"胖" ⇒ 格数严格更多
	var thin := ShapeGenerator.build_star(STAR_POINTS, STAR_OUTER, 0.25)
	var fat := ShapeGenerator.build_star(STAR_POINTS, STAR_OUTER, 0.75)
	assert_gt(_cells(fat).size(), _cells(thin).size(),
			"inner_ratio 越大格数越多（0.25→%d, 0.75→%d）" % [_cells(thin).size(), _cells(fat).size()])
	assert_eq(int((thin["params"] as Dictionary).get("points", -1)), STAR_POINTS, "角数回写")


# ==================== ③ 扇形：只落在角区间 ====================

func test_sector_cells_stay_inside_angular_range() -> void:
	var t := ShapeGenerator.build_sector(SECTOR_R, SECTOR_A0, SECTOR_A1)
	_assert_outline_invariants(t, "sector")
	_assert_consumable(t, "sector")
	var apex := 0
	for p in _cells(t):
		var d := Vector2(p) - _center(SECTOR_R)
		assert_true(d.length() <= float(SECTOR_R) + 0.5,
				"扇形格心 %s 到顶点距 %.4f 必须 ≤ 半径 + 半格 %.1f" % [str(p), d.length(), SECTOR_R + 0.5])
		if d.length() <= 0.0001:
			apex += 1
			continue          # 顶点格：角度未定义，单列
		var ang := fposmod(rad_to_deg(atan2(d.y, d.x)), 360.0)
		assert_true(ang >= SECTOR_A0 - 0.000001 and ang <= SECTOR_A1 + 0.000001,
				"扇形格 %s 的角度 %.4f 必须落在 [%.0f, %.0f]" % [str(p), ang, SECTOR_A0, SECTOR_A1])
	assert_eq(apex, 1, "扇形顶点格应恰有一个")
	assert_eq(int((t["params"] as Dictionary).get("radius", -1)), SECTOR_R, "params.radius 应回写")


func test_sector_angle_width_controls_size() -> void:
	var quarter := ShapeGenerator.build_sector(SECTOR_R, 0.0, 90.0)
	var full := ShapeGenerator.build_sector(SECTOR_R, 0.0, 360.0)
	assert_gt(_cells(quarter).size(), 0, "90° 扇形应出格")
	assert_gt(_cells(full).size(), _cells(quarter).size(),
			"张角越大格数越多（90°→%d, 360°→%d）" % [_cells(quarter).size(), _cells(full).size()])


# ==================== ④ 非法参数：拒绝 + 可读原因 ====================

func test_invalid_params_rejected_with_readable_reason() -> void:
	var cases: Array = [
		["circle radius=0", ShapeGenerator.build_circle(0)],
		["circle radius<0", ShapeGenerator.build_circle(-3)],
		["circle precision<3", ShapeGenerator.build_circle(5, 2)],
		["star points<3", ShapeGenerator.build_star(2, 8, 0.5)],
		["star outer_radius=0", ShapeGenerator.build_star(5, 0, 0.5)],
		["star inner_ratio=NaN", ShapeGenerator.build_star(5, 8, NAN)],
		["star inner_ratio=0", ShapeGenerator.build_star(5, 8, 0.0)],
		["star inner_ratio>=1", ShapeGenerator.build_star(5, 8, 1.0)],
		["sector radius=0", ShapeGenerator.build_sector(0, 0.0, 90.0)],
		["sector start=NaN", ShapeGenerator.build_sector(8, NAN, 90.0)],
		["sector end=NaN", ShapeGenerator.build_sector(8, 0.0, NAN)],
		["sector start==end", ShapeGenerator.build_sector(8, 90.0, 90.0)],
		["sector end<start", ShapeGenerator.build_sector(8, 200.0, 90.0)],
		["sector start<0", ShapeGenerator.build_sector(8, -10.0, 90.0)],
		["sector end>360", ShapeGenerator.build_sector(8, 0.0, 400.0)],
	]
	for c: Variant in cases:
		var label := str(c[0])
		var t: Dictionary = c[1]
		assert_eq((t.get("positions", []) as Array).size(), 0, "%s：必须拒绝（空格集）" % label)
		assert_eq((t.get("adjacency", []) as Array).size(), 0, "%s：拒绝时邻接也应为空" % label)
		assert_ne(_error_of(t).strip_edges(), "", "%s：拒绝必须给可读原因（error 字段）" % label)


# ==================== ⑤ 超预算：拒绝 + 可读原因 ====================

func test_over_budget_rejected_with_readable_reason() -> void:
	# 上界 > EditorDoc.MAX_CELL_BUDGET（5000）⇒ 硬阻（reason 由 EditorDoc.check_cell_budget 给出）
	var cases: Array = [
		["circle r=50", ShapeGenerator.build_circle(50)],              # 上界 π*51² ≈ 8172
		["star r=60", ShapeGenerator.build_star(4, 60, 0.5)],          # 上界 π*61² ≈ 11689
		["sector r=150 90°", ShapeGenerator.build_sector(150, 0.0, 90.0)],  # 上界 ≈ 17907
	]
	for c: Variant in cases:
		var label := str(c[0])
		var t: Dictionary = c[1]
		assert_eq((t.get("positions", []) as Array).size(), 0, "%s：超预算必须拒绝" % label)
		var reason := _error_of(t)
		assert_ne(reason.strip_edges(), "", "%s：必须给可读原因" % label)
		assert_true(reason.find(str(EditorDoc.MAX_CELL_BUDGET)) != -1 or reason.find("上限") != -1,
				"%s：原因应点明超上限 %d（实际：%s）" % [label, EditorDoc.MAX_CELL_BUDGET, reason])


func test_warn_band_still_generates() -> void:
	# 估算落在 (DEFAULT 500, MAX 5000] ⇒ 只是 warn 档（ok=true），不得误伤为拒绝
	var t := ShapeGenerator.build_circle(14)      # 上界 π*225 ≈ 707 > 500 且 ≤ 5000
	assert_gt(_cells(t).size(), 0, "warn 档（> DEFAULT 500 但 ≤ MAX）应照常生成")
	assert_eq(_error_of(t), "", "warn 档不应带 error")


# ==================== ⑥ 既有族行为未变（冒烟对照） ====================

func test_existing_hex_unchanged() -> void:
	var hex := ShapeGenerator.build_hex(3)
	_assert_outline_invariants(hex, "hex(3)", ShapeGenerator.HEX6)
	assert_eq(_cells(hex).size(), 7, "hex(3) 应 7 格")
	assert_eq((hex["adjacency"] as Array).size(), 12, "hex(3) 应 12 边（盘心 6 + 外环 6）")
	assert_eq(str(hex["style"]), "hex", "style 应保持 hex")
	assert_eq(hex["params"], {"size": 3}, "params 应保持 {size:3}")
	var hex5 := ShapeGenerator.build_hex(5)
	assert_eq(_cells(hex5).size(), 19, "hex(5) 应 19 格")
	assert_eq((hex5["adjacency"] as Array).size(), 42, "hex(5) 应 42 边")


func test_existing_holed_grid_unchanged() -> void:
	var t := ShapeGenerator.build_holed_grid(3, 3, [Vector2i(1, 1)])
	_assert_outline_invariants(t, "holed_grid(3,3,洞中心)")
	assert_eq(_cells(t).size(), 8, "3×3 挖中心 → 8 格")
	assert_eq(str(t["style"]), "holed_grid", "style 应保持 holed_grid")
	# 与统一入口的产物逐字段一致（既有 9 族不得被新增族影响）
	var g := ShapeGenerator.to_adjacency_grid("holed_grid", {"rows": 3, "cols": 3, "holes": [{"x": 1, "y": 1}]})
	assert_not_null(g, "holed_grid 经统一入口应可建盘")
	assert_eq(g.cell_count(), 8, "统一入口格数应与 build_holed_grid 一致")
