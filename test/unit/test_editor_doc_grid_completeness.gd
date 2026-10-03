# test_editor_doc_grid_completeness.gd —— EditorDoc 盘面格集完整性 + estimate_cells 三族对拍
# （editor-batch5，2026-10-03）
#
# 钉住的不变量（坏一条，编辑器就会"盘明明 36 格却少一格"或"预算估算与真实盘漂移"）：
#   1) 小方盘（6×6）格集必须完整：`grid().all_positions()` == rows*cols，一格不缺；
#   2) 6×6 在各种邻域/环绕/含自身配置下都完整（缓存/拓扑路径不许悄悄丢格）；
#   3) 9×9 方盘仍完整（回归护栏）；
#   4) 洞盘 / 环绕盘不凭空多格 —— 有障碍的盘按"挖洞后"计数；
#   5) `estimate_cells` 对 circle / star / sector 三族**逐族**与真实 `ShapeGenerator.build_*`
#      的 `positions.size()` 对拍一致（生成器只读使用，不建盘不落盘）。
extends GutTest


# ==================== 1. 方格盘完整性 ====================

func _grid_set(d: EditorDoc) -> Dictionary:
	var got := {}
	for p in d.grid().all_positions():
		got[p] = true
	return got


func _missing_of(d: EditorDoc) -> Array:
	var got := _grid_set(d)
	var miss: Array = []
	for y in d.rows:
		for x in d.cols:
			if not got.has(Vector2i(x, y)):
				miss.append(Vector2i(x, y))
	return miss


func test_square_6x6_is_complete() -> void:
	var d := EditorDoc.new(6, 6)
	var got := d.grid().all_positions()
	var miss := _missing_of(d)
	assert_eq(got.size(), 36, "6×6 方盘应为 36 格；缺格 = %s" % str(miss))
	assert_true(got.has(Vector2i(2, 0)), "6×6 必须含 (2,0)；缺格 = %s" % str(miss))


func test_square_6x6_complete_across_neighborhoods() -> void:
	# 全盘格集只由 rows/cols 决定，与邻域/环绕/含自身无关 ⇒ 每种配置都必须是 36 格、一格不缺。
	var configs: Array = [
		{"dirs": [], "wrap": false, "self": false},
		{"dirs": [], "wrap": true, "self": false},
		{"dirs": [], "wrap": false, "self": true},
		{"dirs": WrapTopology.DIRS_ORTHO4, "wrap": false, "self": false},
		{"dirs": WrapTopology.DIRS_KNIGHT8, "wrap": true, "self": false},
	]
	for cfg in configs:
		var d := EditorDoc.new(6, 6)
		d.dirs.assign(cfg["dirs"])
		d.wrap = bool(cfg["wrap"])
		d.include_self = bool(cfg["self"])
		var got := d.grid().all_positions()
		assert_eq(got.size(), 36, "6×6 盘格数必须恒为 36（配置 %s）；缺格 = %s" % [str(cfg), str(_missing_of(d))])
		assert_true(got.has(Vector2i(2, 0)), "6×6 必须含 (2,0)（配置 %s）" % str(cfg))


func test_grid_is_fresh_after_obstacle_removed() -> void:
	# 缓存护栏：`struct_signature` 回到旧值时必须重算（旧盘是 35 格的洞盘，绝不能把它当新盘返回）。
	var d := EditorDoc.new(6, 6)
	assert_eq(d.grid().all_positions().size(), 36, "第一次取盘：无洞 6×6 应 36 格")
	d.obstacles = [Vector2i(2, 0)]
	assert_eq(d.grid().all_positions().size(), 35, "挖掉 (2,0) 后应 35 格")
	d.obstacles = []
	var got := d.grid().all_positions()
	assert_eq(got.size(), 36, "洞删除后必须回到 36 格；实际缺格 = %s" % str(_missing_of(d)))
	assert_true(got.has(Vector2i(2, 0)), "洞删除后 (2,0) 必须回到盘上")


func test_square_9x9_still_complete() -> void:
	var d := EditorDoc.new(9, 9)
	var got := d.grid().all_positions()
	assert_eq(got.size(), 81, "9×9 方盘应为 81 格；缺格 = %s" % str(_missing_of(d)))
	assert_true(got.has(Vector2i(2, 0)), "9×9 必须含 (2,0)")


# ==================== 2. 洞盘 / 环绕盘不因本次改动多格 ====================

func test_holed_board_has_no_extra_cells() -> void:
	# 5×5 挖 2 个洞 = 23 格；且洞里不得"长回来"。
	var d := EditorDoc.new(5, 5)
	d.obstacles = [Vector2i(0, 0), Vector2i(2, 2)]
	var got := d.grid().all_positions()
	assert_eq(got.size(), 23, "洞盘应为 25-2=23 格")
	assert_false(got.has(Vector2i(0, 0)), "洞格 (0,0) 不得出现在盘上")
	assert_false(got.has(Vector2i(2, 2)), "洞格 (2,2) 不得出现在盘上")


func test_wrap_board_has_no_extra_cells() -> void:
	# 环绕是"折返"不是"复制"：4×4 环绕盘仍是 16 格（不多不少）。
	var d := EditorDoc.new(4, 4)
	d.wrap = true
	var got := d.grid().all_positions()
	assert_eq(got.size(), 16, "4×4 环绕盘应为 16 格（折返不复制）")


# ==================== 3. estimate_cells 三族逐族对拍真实 build_* ====================

func test_estimate_matches_circle_builder() -> void:
	var cases: Array = [
		{"radius": 2, "precision": 3},
		{"radius": 3, "precision": 24},
		{"radius": 4, "precision": 5},
		{"radius": 5, "precision": 8},
		{"radius": 6, "precision": 24},
		{"radius": 3},                       # precision 缺省 24（与 build_circle 默认一致）
	]
	for p in cases:
		var want: int = ShapeGenerator.build_circle(
			int(p.get("radius", 0)), int(p.get("precision", 24)))["positions"].size()
		assert_gt(want, 0, "circle 用例本身应为合法参数：%s" % str(p))
		assert_eq(EditorDoc.estimate_cells("circle", p, 0, 0), want,
			"circle 估算应与 build_circle 格数一致：%s" % str(p))


func test_estimate_matches_star_builder() -> void:
	var cases: Array = [
		{"points": 3, "outer_radius": 4, "inner_ratio": 0.5},
		{"points": 4, "outer_radius": 5, "inner_ratio": 0.4},
		{"points": 5, "outer_radius": 4, "inner_ratio": 0.5},
		{"points": 5, "outer_radius": 6, "inner_ratio": 0.7},
		{"points": 6, "outer_radius": 5, "inner_ratio": 0.6},
		{"points": 5, "outer_radius": 4},    # inner_ratio 缺省 0.5（与 build_star 默认一致）
	]
	for p in cases:
		var want: int = ShapeGenerator.build_star(
			int(p.get("points", 0)), int(p.get("outer_radius", 0)),
			float(p.get("inner_ratio", 0.5)))["positions"].size()
		assert_gt(want, 0, "star 用例本身应为合法参数：%s" % str(p))
		assert_eq(EditorDoc.estimate_cells("star", p, 0, 0), want,
			"star 估算应与 build_star 格数一致：%s" % str(p))


func test_estimate_matches_sector_builder() -> void:
	var cases: Array = [
		{"radius": 3, "start_deg": 0.0, "end_deg": 90.0},
		{"radius": 4, "start_deg": 0.0, "end_deg": 180.0},
		{"radius": 5, "start_deg": 30.0, "end_deg": 120.0},
		{"radius": 4, "start_deg": 0.0, "end_deg": 360.0},
		{"radius": 5, "start_deg": 270.0, "end_deg": 360.0},
		{"radius": 4},                       # 角度缺省 0→90（UI 默认，与 build_sector 调用侧一致）
	]
	for p in cases:
		var want: int = ShapeGenerator.build_sector(
			int(p.get("radius", 0)), float(p.get("start_deg", 0.0)),
			float(p.get("end_deg", 90.0)))["positions"].size()
		assert_gt(want, 0, "sector 用例本身应为合法参数：%s" % str(p))
		assert_eq(EditorDoc.estimate_cells("sector", p, 0, 0), want,
			"sector 估算应与 build_sector 格数一致：%s" % str(p))


func test_estimate_three_families_reject_invalid_params_as_zero() -> void:
	# 非法参数：build_* 会拒绝（positions 空）⇒ 估算必须同样返回 0（不许静默按方阵兜底）。
	assert_eq(EditorDoc.estimate_cells("circle", {"radius": 0}, 0, 0), 0, "radius=0 非法")
	assert_eq(EditorDoc.estimate_cells("circle", {"radius": 3, "precision": 2}, 0, 0), 0, "precision<3 非法")
	assert_eq(EditorDoc.estimate_cells("star", {"points": 2, "outer_radius": 4}, 0, 0), 0, "points<3 非法")
	assert_eq(EditorDoc.estimate_cells("star", {"points": 5, "outer_radius": 4, "inner_ratio": 1.0}, 0, 0), 0, "ratio=1 非法")
	assert_eq(EditorDoc.estimate_cells("sector", {"radius": 4, "start_deg": 90.0, "end_deg": 90.0}, 0, 0), 0, "start>=end 非法")
