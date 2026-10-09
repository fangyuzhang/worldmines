# test_topology_view.gd —— 拓扑呈现（环绕 / 虫洞）的**视图侧**契约。
#
# 为什么单独一个文件：test_topology_model 守的是"图对不对"，本文件守的是
# "玩家看得见看不见"——呈现元数据必须真的被 BoardView 认出来，几何必须真的落在格内、
# 真的连到两端格心。绘制函数本身（draw_*）只在引擎的 _draw 遍里合法，
# 所以这里只断言**纯几何/纯状态**：几何被拆成 _portal_* 这些不碰 draw_* 的纯函数正是为此。
extends GutTest

var _view

func before_each() -> void:
	_view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(_view)

func after_each() -> void:
	GameSession.start_level("res://levels/classic_01.json")

func _install_board(level: Dictionary) -> Board:
	var b := Board.new()
	b.load_level(level)
	GameSession.board = b
	_view._connect_board()
	return b

## 一块 3x5 强制拓扑盘（force=true ⇒ 即使默认邻域也产出邻接表），再挂一对虫洞。
func _wormhole_level() -> Dictionary:
	var built := WrapTopology.build(3, 5, ShapeGenerator.MOORE8, false, false, true)
	assert_true(bool(built["ok"]), "应能构建 3x5 拓扑：%s" % str(built["reason"]))
	var topo: Dictionary = built["topology"]
	var attached := TopologyModel.attach_portals(topo, [
		{"a": {"x": 0, "y": 0}, "b": {"x": 4, "y": 2}, "id": "A"},
	])
	assert_true(bool(attached["ok"]), "虫洞应能写入：%s" % str(attached["errors"]))
	return {
		"name": "虫洞测试",
		"size": {"rows": 3, "cols": 5},
		"total_mines": 2,
		"mines": [{"r": 1, "c": 2}, {"r": 0, "c": 3}],
		"revealed": [{"r": 0, "c": 0}],
		"topology": attached["topology"] as Dictionary,
	}

## 一块 5x5 环绕盘（view_meta.kind == wrap）。
func _wrap_level() -> Dictionary:
	var built := WrapTopology.build(5, 5, ShapeGenerator.MOORE8, false, true, true)
	assert_true(bool(built["ok"]), "应能构建环绕盘")
	return {
		"name": "环绕测试",
		"size": {"rows": 5, "cols": 5},
		"total_mines": 2,
		"mines": [{"r": 1, "c": 2}, {"r": 0, "c": 3}],
		"revealed": [{"r": 0, "c": 0}],
		"topology": built["topology"] as Dictionary,
	}


## 一块 4x6 折叠盘（force=true ⇒ 产出邻接表）：折痕在 x=3 —— 左边 3 列近侧 / 右边 3 列远侧。
func _fold_level() -> Dictionary:
	var built := WrapTopology.build(4, 6, ShapeGenerator.MOORE8, false, false, true)
	assert_true(bool(built["ok"]), "应能构建 4x6 拓扑：%s" % str(built.get("reason", "")))
	var attached := TopologyModel.attach_fold(built["topology"] as Dictionary, {"axis": "x", "at": 3})
	assert_true(bool(attached["ok"]), "折叠应能写入：%s" % str(attached["errors"]))
	return {
		"name": "折叠测试",
		"size": {"rows": 4, "cols": 6},
		"total_mines": 2,
		"mines": [{"r": 1, "c": 2}, {"r": 0, "c": 3}],
		"revealed": [{"r": 0, "c": 0}],
		"topology": attached["topology"] as Dictionary,
	}


func test_wormhole_view_meta_exposes_portals() -> void:
	var b := _install_board(_wormhole_level())
	assert_true(b.grid is AdjacencyGrid, "带 topology 的关卡应走邻接表网格")
	var meta: Dictionary = _view._view_meta()
	assert_eq(str(meta.get("kind", "")), TopologyModel.VIEW_WORMHOLE, "视图应识别为虫洞盘")
	var portals: Array = meta.get("portals", [])
	assert_eq(portals.size(), 1, "视图应暴露一条虫洞对")
	assert_eq(portals[0]["a"], Vector2i(0, 0), "A 端坐标")
	assert_eq(portals[0]["b"], Vector2i(4, 2), "B 端坐标")


func test_wrap_view_meta_reports_both_axes() -> void:
	_install_board(_wrap_level())
	var meta: Dictionary = _view._view_meta()
	assert_eq(str(meta.get("kind", "")), TopologyModel.VIEW_WRAP, "视图应识别为环绕盘")
	var axes: Dictionary = _view._wrap_axes()
	assert_true(bool(axes["horizontal"]), "环绕盘应开横轴")
	assert_true(bool(axes["vertical"]), "环绕盘应开纵轴")


func test_portal_badge_sits_inside_the_cell() -> void:
	_install_board(_wormhole_level())
	var r: Rect2 = _view._cell_rect(Vector2i(0, 0))
	var at: Vector2 = _view._portal_badge_at(Vector2i(0, 0))
	assert_true(r.has_point(at), "徽章圆心必须落在格内")
	assert_true(at.x > r.position.x and at.y > r.position.y, "徽章应偏向格内左上")
	var rad: float = _view._portal_badge_radius(Vector2i(0, 0), 1.0)
	assert_gt(rad, 0.0, "徽章半径应为正")
	assert_lt(rad * 2.0, r.size.x, "徽章不应大过格子")


func test_portal_tunnel_connects_both_centers_and_bows() -> void:
	_install_board(_wormhole_level())
	var a := Vector2i(0, 0)
	var b := Vector2i(4, 2)
	var pts: PackedVector2Array = _view._portal_tunnel_points(a, b)
	assert_gt(pts.size(), 2, "通道应是折线（至少 3 点）")
	assert_true(pts[0].is_equal_approx(_view._cell_center(a)), "通道起点必须是 A 格心")
	assert_true(pts[pts.size() - 1].is_equal_approx(_view._cell_center(b)), "通道终点必须是 B 格心")
	var mid: Vector2 = pts[pts.size() / 2]
	var chord_mid: Vector2 = (_view._cell_center(a) + _view._cell_center(b)) * 0.5
	assert_gt(mid.distance_to(chord_mid), 0.5, "中点应外弓，不与弦重合")


func test_portal_colors_are_distinct_within_a_set() -> void:
	_install_board(_wormhole_level())
	var seen := {}
	for i in 6:
		var c: Color = _view._portal_color(i, 6)
		seen[snappedf(c.h, 0.001)] = true
	assert_eq(seen.size(), 6, "同一组里的虫洞颜色应两两可分")


# ==================== 不可能几何：连接透镜（2026-10-09） ====================
#
# 守的是「错觉盘上，看着相邻 ≠ 真的相邻」这件事**被真的算出来了**：
# 等轴菱面把每个方块画成三个菱形面，屏幕上**顶点相接**的两格看着碰在一起，但引擎里
# 只有**共边**才算邻居。_impossible_pairs() 把这两批位置分开（seams / ghosts），
# 绘制函数只是把它们画出来 —— 所以这里断言纯数据，不碰 draw_*。

## 一块等轴菱面盘：直接用真关卡 iso_01.json。
## custom_shapes 是**渲染几何**，LevelLoader 才会把它挂到 board 的 meta 上；本测试自己
## 建 Board，就照做同一步（否则 _custom_layout() 为假、透镜无从谈起）。
func _install_iso_level() -> Board:
	var f := FileAccess.open("res://levels/iso_01.json", FileAccess.READ)
	assert_not_null(f, "前置：res://levels/iso_01.json 应存在")
	if f == null:
		return null
	var raw: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	assert_true(raw is Dictionary, "iso_01.json 应是字典")
	var lv: Dictionary = raw
	var b := Board.new()
	b.load_level(lv)
	b.set_meta("custom_shapes", lv["custom_shapes"])
	GameSession.board = b
	_view._connect_board()
	return b


## 无向边数 = 每格邻居数之和的一半（与实现里的去重口径无关，独立算一遍）。
func _undirected_edge_count(grid: GridInterface) -> int:
	var inc := 0
	for pos in grid.all_positions():
		inc += grid.get_neighbors(pos).size()
	assert_eq(inc % 2, 0, "邻接表必须对称（邻居总数应为偶数）")
	return inc / 2


func test_impossible_level_is_recognised_and_supports_lens() -> void:
	_install_iso_level()
	assert_eq(str(_view._view_meta().get("kind", "")), TopologyModel.VIEW_IMPOSSIBLE,
			"等轴菱面盘应被识别为不可能几何")
	assert_true(_view.supports_lens(), "等轴菱面盘应支持连接透镜")


func test_lens_is_not_offered_on_other_topologies() -> void:
	_install_board(_wrap_level())
	assert_false(_view.supports_lens(), "环绕盘没有「看着相邻」的错觉，不应提供透镜")
	var pairs: Dictionary = _view._impossible_pairs()
	assert_eq((pairs["seams"] as Array).size(), 0, "非错觉盘不该算出实缝")
	assert_eq((pairs["ghosts"] as Array).size(), 0, "非错觉盘不该算出角接")


func test_lens_seams_are_exactly_the_graph_edges() -> void:
	var b := _install_iso_level()
	var grid: GridInterface = b.grid
	var pairs: Dictionary = _view._impossible_pairs()
	var seams: Array = pairs["seams"]
	assert_eq(seams.size(), _undirected_edge_count(grid),
			"实缝应**逐条**对上邻接表：每一条真邻接恰好一枚钉、不多不少")
	for rec: Variant in seams:
		var d: Dictionary = rec
		var a: Vector2i = d["a"]
		var nb: Vector2i = d["b"]
		assert_true(grid.get_neighbors(a).has(nb), "实缝两端必须是真邻居：%s-%s" % [a, nb])
		# 钉在共享边中点上 ⇒ 必须落在两格各自的多边形包围盒里（边中点就在边界上，
		# 故按 grow 半个像素判，只排除「画到别的格上」这类结构性错误）。
		var at: Vector2 = _view._custom_world_to_screen(d["at"])
		assert_true(_view._cell_rect(a).grow(0.5).has_point(at), "钉应在 A 格范围内")
		assert_true(_view._cell_rect(nb).grow(0.5).has_point(at), "钉应在 B 格范围内")


func test_lens_ghosts_are_vertex_touches_that_are_not_adjacent() -> void:
	var b := _install_iso_level()
	var grid: GridInterface = b.grid
	var ghosts: Array = (_view._impossible_pairs()["ghosts"] as Array)
	assert_gt(ghosts.size(), 0, "等轴菱面盘**必须有**角接：这正是「看不清凸凹」的来源")
	for rec: Variant in ghosts:
		var d: Dictionary = rec
		var a: Vector2i = d["a"]
		var nb: Vector2i = d["b"]
		assert_false(grid.get_neighbors(a).has(nb),
				"角接两端**不得**是真邻居（否则就不是错觉了）：%s-%s" % [a, nb])
		# 只共享一个顶点 ⇒ 该点必须同时是两个多边形的顶点。
		var at: Vector2 = d["at"]
		assert_true(_impl_has_vertex(a, at), "角接点应是 A 格的顶点")
		assert_true(_impl_has_vertex(nb, at), "角接点应是 B 格的顶点")


## 某格的多边形里是否含有这个**世界坐标**顶点（按 1e-4 量化比对，与实现同口径）。
func _impl_has_vertex(pos: Vector2i, world_at: Vector2) -> bool:
	var c: Dictionary = _view._custom_cell(pos)
	if c.is_empty():
		return false
	var want: Vector2i = _world_vkey(world_at)
	# `_custom_cell(pos)["poly"]` 已是世界绝对坐标（不要再叠格心）。
	for v: Vector2 in (c["poly"] as PackedVector2Array):
		if _world_vkey(v) == want:
			return true
	return false


## 世界坐标顶点 → 量化键（与 BoardView._impl_vkey 同口径：1e4 分辨率）。
func _world_vkey(v: Vector2) -> Vector2i:
	return Vector2i(int(round(v.x * 10000.0)), int(round(v.y * 10000.0)))


func test_lens_toggle_flips_and_redraws() -> void:
	_install_iso_level()
	assert_false(_view.lens_enabled(), "透镜默认关（只在悬停格上出现）")
	assert_true(_view.toggle_lens(), "第一次点开")
	assert_true(_view.lens_enabled(), "开态应可读回")
	assert_false(_view.toggle_lens(), "再点收起")
	assert_false(_view.lens_enabled(), "关态应可读回")


func test_hud_lens_button_appears_only_on_impossible_boards() -> void:
	# ① 普通盘：右列不该多一枚按了没反应的死按钮
	_install_board(_wrap_level())
	var hud_a: Control = load("res://ui/hud.tscn").instantiate()
	_view.add_child(hud_a)
	assert_null(hud_a.get("_lens_btn"), "环绕盘的 HUD 不应装透镜按钮")
	assert_eq(hud_a._right_col.get_child_count(), 3, "非错觉盘的右列仍是 提示/撤销/暂停")
	hud_a.queue_free()
	# ② 错觉盘：HUD 进场就装上，且点一下真的切到 BoardView 的开关
	_install_iso_level()
	var hud_b: Control = load("res://ui/hud.tscn").instantiate()
	_view.add_child(hud_b)
	var lens_btn: Button = hud_b.get("_lens_btn") as Button
	assert_not_null(lens_btn, "等轴菱面盘的 HUD 应装上透镜按钮")
	assert_eq(hud_b._right_col.get_child_count(), 4, "错觉盘的右列 = 提示/撤销/暂停 + 透镜")
	if lens_btn == null:
		return
	assert_not_null(lens_btn.icon, "透镜按钮应带图标（图标解析失败会静默降级为空）")
	assert_ne(str(lens_btn.tooltip_text), "", "纯图标/短标签按钮必须带 tooltip")
	lens_btn.pressed.emit()
	assert_true(_view.lens_enabled(), "点透镜应真的切到 BoardView 的开关")
	hud_b.queue_free()


# ==================== 静态折叠（折叠盘，2026-10-09） ====================
#
# 守的是「远侧翻过来压住近侧」这件事**被真的算出来又真的画出来**：
#   · 拓扑侧：配对必须逐条对上镜像（a.x + b.x = 2*at-1）且两端是真邻居（与模型层同判据）；
#   · 视图侧：折叠盘才提供折叠视图、折痕画在两半之间、开关能真的翻面。
func test_fold_level_is_recognised_and_supports_fold() -> void:
	_install_board(_fold_level())
	assert_eq(str(_view._view_meta().get("kind", "")), TopologyModel.VIEW_FOLD,
			"折叠盘应被识别为折叠")
	assert_true(_view.supports_fold(), "折叠盘应支持折叠视图")


func test_fold_is_not_offered_on_other_topologies() -> void:
	_install_board(_wrap_level())
	assert_false(_view.supports_fold(), "环绕盘没有折叠，不应提供折叠视图")
	assert_eq((_view._fold_pairs() as Array).size(), 0, "非折叠盘不该算出配对")


func test_fold_pairs_are_mirror_images_and_real_neighbours() -> void:
	var b := _install_board(_fold_level())
	var pairs: Array = _view._fold_pairs()
	assert_eq(pairs.size(), 12, "6 列、at=3 ⇒ 3 列近侧 × 4 行 = 12 对")
	var grid: GridInterface = b.grid
	for pr_v: Variant in pairs:
		var pr: Dictionary = pr_v
		var a: Vector2i = pr["a"]
		var c: Vector2i = pr["b"]
		assert_true(grid.in_board(a) and grid.in_board(c), "配对两端都必须在盘上：%s-%s" % [a, c])
		assert_true(grid.get_neighbors(a).has(c), "叠合的两格必须是真邻居：%s-%s" % [a, c])
		assert_eq(a.x + c.x, 5, "两格必须关于折痕镜像（2*3-1=5）：%s-%s" % [a, c])
		assert_eq(a.y, c.y, "折合不跨行：%s-%s" % [a, c])


func test_fold_crease_segment_sits_between_the_two_halves() -> void:
	_install_board(_fold_level())
	var seg: PackedVector2Array = _view._fold_crease_segment(FoldModel.AXIS_X, 3)
	assert_eq(seg.size(), 2, "x 轴折痕应是一条线段（两个端点）")
	assert_almost_eq(seg[0].x, seg[1].x, 0.001, "x 轴折痕是**竖直线**（两端 x 相同）")
	assert_lt(seg[0].y, seg[1].y, "线段应从包围盒上沿贯到下沿")
	var c_left: Vector2 = _view._cell_center(Vector2i(2, 0))
	var c_right: Vector2 = _view._cell_center(Vector2i(3, 0))
	assert_gt(seg[0].x, c_left.x, "折痕应在近侧格心右侧")
	assert_lt(seg[0].x, c_right.x, "折痕应在远侧格心左侧")
	assert_almost_eq(seg[0].x, (c_left.x + c_right.x) * 0.5, 0.001, "折痕应落在相邻两格心中点")


func test_fold_toggle_flips_and_redraws() -> void:
	_install_board(_fold_level())
	assert_false(_view.fold_flat_enabled(), "折叠视图默认是「折起来」")
	assert_true(_view.toggle_fold_view(), "第一次点开摊平")
	assert_true(_view.fold_flat_enabled(), "摊平态应可读回")
	assert_false(_view.toggle_fold_view(), "再点折起来")
	assert_false(_view.fold_flat_enabled(), "折起态应可读回")


func test_hud_fold_button_appears_only_on_fold_boards() -> void:
	# ① 环绕盘：右列不该多一枚按了没反应的死按钮
	_install_board(_wrap_level())
	var hud_a: Control = load("res://ui/hud.tscn").instantiate()
	_view.add_child(hud_a)
	assert_null(hud_a.get("_fold_btn"), "环绕盘的 HUD 不应装折叠按钮")
	hud_a.queue_free()
	# ② 折叠盘：HUD 进场就装上，且点一下真的切到 BoardView 的开关
	_install_board(_fold_level())
	var hud_b: Control = load("res://ui/hud.tscn").instantiate()
	_view.add_child(hud_b)
	var fold_btn: Button = hud_b.get("_fold_btn") as Button
	assert_not_null(fold_btn, "折叠盘的 HUD 应装上折叠按钮")
	if fold_btn == null:
		return
	assert_not_null(fold_btn.icon, "折叠按钮应带图标（图标解析失败会静默降级为空）")
	assert_ne(str(fold_btn.tooltip_text), "", "纯图标按钮必须带 tooltip")
	fold_btn.pressed.emit()
	assert_true(_view.fold_flat_enabled(), "点折叠按钮应真的切到 BoardView 的开关")
	hud_b.queue_free()

# ==================== D. 折纸族（多折痕）的呈现契约 ====================
#
# 单折与多折共用同一条绘制路径（_draw_fold_hints），区别只在折痕有几条。
# 这里只断言**纯几何 / 纯状态**：每折各一条折痕线、每一折的"翻走的纸"互不重叠、
# 同一格的所有叠合层都连得出来（画布函数没法断言，几何查询测得动）。

## 一块 6x6 双折盘：先左右折（x@3）、再上下折（y@3）⇒ 左上 3x3 区每格摞 4 层。
func _paper_fold_level() -> Dictionary:
	var built := WrapTopology.build(6, 6, ShapeGenerator.MOORE8, false, false, true)
	assert_true(bool(built["ok"]), "应能构建 6x6 拓扑：%s" % str(built.get("reason", "")))
	var decl := {"folds": [{"axis": "x", "at": 3}, {"axis": "y", "at": 3}]}
	var attached := TopologyModel.attach_fold(built["topology"] as Dictionary, decl)
	assert_true(bool(attached["ok"]), "双折应能写入：%s" % str(attached["errors"]))
	return {
		"name": "折纸测试",
		"size": {"rows": 6, "cols": 6},
		"total_mines": 2,
		"mines": [{"r": 1, "c": 2}, {"r": 0, "c": 3}],
		"revealed": [{"r": 0, "c": 0}],
		"topology": attached["topology"] as Dictionary,
	}


## 两条折痕都要被认出来、都要有落位线段（横折竖折各一条），且 HUD 开关照样装上。
func test_paper_fold_board_shows_every_crease() -> void:
	_install_board(_paper_fold_level())
	assert_true(_view.supports_fold(), "折纸盘（多折）也要支持折叠视图")
	var folds: Array = _view._fold_folds()
	assert_eq(folds.size(), 2, "应读出两条折痕（读侧只认单折 = 折纸族按钮装不上）")
	assert_eq(str(folds[0]["axis"]), "x", "第一条是左右折")
	assert_eq(str(folds[1]["axis"]), "y", "第二条是上下折")
	var creases: Array = _view._fold_creases()
	assert_eq(creases.size(), 2, "每一折都该画出一条折痕线")
	var c0: Dictionary = creases[0]
	var c1: Dictionary = creases[1]
	var s0: PackedVector2Array = c0["seg"]
	var s1: PackedVector2Array = c1["seg"]
	assert_almost_eq(s0[0].x, s0[1].x, 0.001, "x 轴折痕该是竖直线")
	assert_almost_eq(s1[0].y, s1[1].y, 0.001, "y 轴折痕该是水平线")


## 两折各自的"翻走的纸"必须**互不重叠**，且合起来正好是被折掉的那些格。
func test_paper_fold_flaps_are_disjoint_and_cover_the_folded_area() -> void:
	_install_board(_paper_fold_level())
	var folds: Array = _view._fold_folds()
	var flap0: Array = _view._fold_flap_cells(folds, 0)
	var flap1: Array = _view._fold_flap_cells(folds, 1)
	assert_eq(flap0.size(), 18, "第 1 折翻走右半 3 列 × 6 行 = 18 格")
	assert_eq(flap1.size(), 9, "第 2 折只翻剩下纸面的下半 3 行 × 3 列 = 9 格（不是 18）")
	for p: Vector2i in flap1:
		assert_false(flap0.has(p), "两折翻走的纸不许重叠：%s" % str(p))
	assert_true(flap0.has(Vector2i(5, 5)), "右上角应被第 1 折翻走")
	assert_false(flap1.has(Vector2i(5, 5)), "右上角已不在纸面上，不该再算进第 2 折")


## 同一格被好几层压着时，每一层都要连得出来（悬停要能一次看清整摞）。
func test_paper_fold_links_every_layer_of_a_stack() -> void:
	var b := _install_board(_paper_fold_level())
	var pairs: Array = _view._fold_pairs()
	assert_eq(pairs.size(), 54, "6x6 两折 ⇒ 只剩 9 摞、每摞 4 层：9 × C(4,2) = 54 对（摞内两两相连）")
	var partners: Array = []
	for pr_v: Variant in pairs:
		var pr: Dictionary = pr_v
		if pr["a"] == Vector2i(0, 0):
			partners.append(pr["b"])
		elif pr["b"] == Vector2i(0, 0):
			partners.append(pr["a"])
	assert_eq(partners.size(), 3, "左上角那一格被 3 层压着 ⇒ 该连出 3 条叠合线")
	var grid: GridInterface = b.grid
	for q: Vector2i in partners:
		assert_true(grid.get_neighbors(Vector2i(0, 0)).has(q),
			"每一条叠合线都必须对应真实的邻接边：%s" % str(q))