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
