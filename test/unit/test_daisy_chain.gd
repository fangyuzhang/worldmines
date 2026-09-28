# test_daisy_chain.gd —— T-D2：数据驱动的「自定义多边形棋盘」（复刻 Tametsi 雏菊链）
#
# 三层断言，各自独立可读：
#   ① 关卡层：LevelLoader 载入 → 拓扑规模指纹（211 格 / 582 无向边 / 61 雷 / 30 初始翻开）
#   ② 数据层：custom_shapes 自检（211 条 cells、poly 顶点数 {5:180, 6:31}、hl 7 种模式、
#      group 计数、绕序一致、hl 索引不越界、格心唯一且落在 bbox 内、格心在自格内）
#   ③ 渲染几何层：board_view 的 **static 纯函数**（custom_visual_bounds / custom_layout_for /
#      custom_apothem / custom_point_in_cell）与实例接线（_cell_center / _cell_polygon / _pick /
#      绘画层换算互补）——不实例化场景也能验证的那部分全部走 static。
#
# ⚠️ 精度口径（与 test_shape_style.gd 同源）：Godot 的 Vector2 分量是 32 位浮点，
#    凡经过 Vector2 的世界量（~100 量级）只有 ~1e-5 相对精度 ⇒ 世界量用 WORLD_EPS=1e-2，
#    无量纲比值用 RATIO_EPS=1e-5。这些都远小于一个像素，不影响断言的实际约束力。
extends GutTest

## board_view 脚本本体（取 static 纯函数与常量；它没有 class_name，故 load 后用）。
const BV := preload("res://ui/board_view.gd")
const LEVEL := "res://levels/daisy_chain.json"
const CLASSIC := "res://levels/classic_01.json"
const WORLD_EPS := 1e-2
const RATIO_EPS := 1e-5
## 默认视口的可用区（1280×720；左右各 24、上 HUD64+24、下 24+底栏 64）。
## 注：2026-09-28 起 board_view._layout 还会扣除 HUD 左右侧列（2×HUD_SIDE_RESERVE）——
## 本文件测纯函数（avail 由调用方给定），用旧口径常量不受影响。
const AVAIL_W := 1232.0
const AVAIL_H := 544.0
const AVAIL_CENTER := Vector2(640.0, 64.0 + 272.0)

## ===== 基线指纹（任务书实测值；数字变了先红灯，再判断是数据还是渲染的问题）=====
const CELL_COUNT := 211
const EDGE_COUNT := 582          # 无向边（JSON adjacency 条数 = 邻接表双向条目数 ÷ 2）
const MINE_COUNT := 61
const REVEALED_COUNT := 30
const POLY_HIST := {5: 180, 6: 31}
## 7 种 hl 模式：31 个六边形同向 (0,1,2,3)；180 个五边形 6 种朝向 × 30。
const HL_MODES := {
	"0,1,2,3": 31, "0,4,3": 30, "1,0,4": 30, "2,1,0": 30,
	"3,2,1": 30, "3,2,1,0": 30, "4,3,2": 30,
}
## group："" 代表 JSON 的 null（本任务不显示分组配色，只断言数据在）。
const GROUP_HIST := {"": 120, "YELLOW": 7, "PINK_DARK": 84}
const TAPER_HIST := {"true|true": 151, "true|false": 30, "false|true": 30}

var _json: Dictionary = {}
var _board: Board = null


func before_all() -> void:
	_json = _read_json()
	_board = LevelLoader.load_level(LEVEL)


func after_all() -> void:
	if GameSession.state == GameSession.State.PAUSED:
		GameSession.set_paused(false)


# ==================== 工具 ====================

func _read_json() -> Dictionary:
	if not FileAccess.file_exists(LEVEL):
		return {}
	var f := FileAccess.open(LEVEL, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _shapes() -> Dictionary:
	return _json.get("custom_shapes", {})


func _cells() -> Array:
	return _shapes().get("cells", [])


## Array[int] → "a,b,c"（做指纹字典的键；Godot 的 Array 不能直接当 Dictionary 键）。
func _hl_key(hl: Array) -> String:
	var parts := PackedStringArray()
	for i in hl:
		parts.append(str(int(i)))
	return ",".join(parts)


## 相对顶点数组（JSON）→ PackedVector2Array。
func _poly_of(cell: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in (cell.get("poly", []) as Array):
		out.append(Vector2(float(v[0]), float(v[1])))
	return out


## 世界坐标下的格心。
func _center_of(cell: Dictionary) -> Vector2:
	var c: Array = cell["center"]
	return Vector2(float(c[0]), float(c[1]))


## 有向邻接条目总数（= 无向边 × 2；与 core 的邻接表实现互为独立核对）。
func _directed_edges() -> int:
	var n := 0
	for p in _board.grid.all_positions():
		n += _board.grid.get_neighbors(p).size()
	return n


# ==================== ① 关卡层：载入与规模指纹 ====================

func test_level_loads_with_baseline_fingerprint() -> void:
	assert_not_null(_board, "daisy_chain.json 应能载入（LevelLoader 的校验是安全边界，不得改）")
	if _board == null:
		return
	assert_true(_board.grid is AdjacencyGrid, "应是异形（邻接表）棋盘，而不是行列方格")
	assert_eq(_board.grid.cell_count(), CELL_COUNT, "格子数应为 211")
	assert_eq((_json.get("topology", {}).get("adjacency", []) as Array).size(), EDGE_COUNT,
			"topology.adjacency 应为 582 条无向边")
	assert_eq(_directed_edges(), EDGE_COUNT * 2, "邻接表应把每条无向边存成双向（582×2=1164）")
	assert_eq(_board.total_mines, MINE_COUNT, "总雷数 61")
	assert_eq(_board.get_mine_positions().size(), MINE_COUNT, "雷位表 61 条")
	# 初始翻开：Board 没有 get_revealed_positions（已确认），按 cell.state 计数即为等价 API。
	var revealed := 0
	for p in _board.grid.all_positions():
		var cell := _board.grid.get_cell(p)
		if cell != null and cell.state == Cell.State.REVEALED:
			revealed += 1
	assert_eq(revealed, REVEALED_COUNT, "初始翻开 30 格")
	# 与 JSON 原文互为核对（防止「只有 Board 会翻」的错觉）
	assert_eq((_json.get("revealed", []) as Array).size(), REVEALED_COUNT, "JSON 的 revealed 也应是 30 条")


func test_mine_and_revealed_sets_are_disjoint() -> void:
	# 雷位与初始翻开无交集：否则这关一载入就判负（数据坏）。
	if _board == null:
		return
	var mines := {}
	for m in _board.get_mine_positions():
		mines[m] = true
	for rv in (_json.get("revealed", []) as Array):
		var pos := Vector2i(int(rv["c"]), int(rv["r"]))
		assert_false(mines.has(pos), "初始翻开格 (%d,%d) 不得是雷" % [pos.x, pos.y])
		assert_not_null(_board.grid.get_cell(pos), "初始翻开格 (%d,%d) 应在盘内" % [pos.x, pos.y])


func test_level_loader_injects_render_meta() -> void:
	# T-D2 的唯一 loader 改动：把两段**展示数据**挂到 board 的 meta 上（core 无感）。
	if _board == null:
		return
	assert_true(_board.has_meta("custom_shapes"), "loader 应注入 custom_shapes meta")
	assert_true(_board.has_meta("palette"), "loader 应注入 palette meta")
	assert_true(_board.get_meta("custom_shapes") is Dictionary, "custom_shapes 应是字典")
	assert_true(_board.get_meta("palette") is Dictionary, "palette 应是字典")


func test_rect_levels_have_no_custom_meta() -> void:
	# 零回归的结构性保证：矩形/蜂窝关卡没有这层 meta ⇒ 渲染层自定义分支必然关闭。
	var b: Board = LevelLoader.load_level(CLASSIC)
	assert_not_null(b, "经典关卡应能载入")
	if b == null:
		return
	assert_false(b.has_meta("custom_shapes"), "经典关卡不得有 custom_shapes meta")
	assert_true(b.grid is RectGrid, "经典关卡仍是行列方格")
	assert_eq(b.grid.cell_count(), b.grid.size().x * b.grid.size().y, "矩形盘格数 = 行×列")


# ==================== ② 数据层：custom_shapes 自检 ====================

func test_cells_polygon_and_pattern_fingerprint() -> void:
	assert_eq(_cells().size(), CELL_COUNT, "custom_shapes.cells 应为 211 条")
	var poly_hist := {}
	var hl_hist := {}
	var taper_hist := {}
	var group_hist := {}
	var key_set := {}
	var oob: Array = []
	for c in _cells():
		var cell: Dictionary = c
		var n: int = (cell["poly"] as Array).size()
		poly_hist[n] = int(poly_hist.get(n, 0)) + 1
		hl_hist[_hl_key(cell["hl"])] = int(hl_hist.get(_hl_key(cell["hl"]), 0)) + 1
		var tp: Array = cell["taper"]
		taper_hist["%s|%s" % [str(bool(tp[0])), str(bool(tp[1]))]] = int(
				taper_hist.get("%s|%s" % [str(bool(tp[0])), str(bool(tp[1]))], 0)) + 1
		var gk: String = "" if cell.get("group") == null else str(cell.get("group"))
		group_hist[gk] = int(group_hist.get(gk, 0)) + 1
		key_set["%d,%d" % [int(cell["x"]), int(cell["y"])]] = true
		# hl 索引必须落在本格 poly 内（越界 = 数据坏；渲染侧也会整格跳过，绝不画错线）
		for i in (cell["hl"] as Array):
			if int(i) < 0 or int(i) >= n:
				oob.append("%d,%d -> hl %s (poly %d)" % [int(cell["x"]), int(cell["y"]), str(cell["hl"]), n])
	assert_eq(poly_hist, POLY_HIST, "顶点数分布应为 {5:180, 6:31}")
	assert_eq(hl_hist, HL_MODES, "hl 应恰好是那 7 种模式（顺序即图案，错一个数字就不对）")
	assert_eq(taper_hist, TAPER_HIST, "taper 分布应为 {true|true:151, true|false:30, false|true:30}")
	assert_eq(group_hist, GROUP_HIST, "group 计数应为 {null:120, YELLOW:7, PINK_DARK:84}")
	assert_eq(key_set.size(), CELL_COUNT, "格键两两不重复")
	assert_eq(oob, [], "hl 索引不得越界：%s" % str(oob))


func test_cells_keys_match_topology_positions() -> void:
	# cells 的整数格键必须与 topology.positions 完全一致（渲染查表与逻辑棋盘同一套键）。
	var topo_keys := {}
	for p in (_json.get("topology", {}).get("positions", []) as Array):
		topo_keys["%d,%d" % [int(p["x"]), int(p["y"])]] = true
	var cell_keys := {}
	for c in _cells():
		cell_keys["%d,%d" % [int(c["x"]), int(c["y"])]] = true
	assert_eq(cell_keys.size(), CELL_COUNT, "cells 格键数 211")
	assert_eq(cell_keys, topo_keys, "cells 的格键集合必须与 topology.positions 完全相同")


func test_geometry_invariants_of_custom_shapes() -> void:
	var bbox: Array = _shapes()["bbox"]
	var bb_w: float = float(bbox[2]) - float(bbox[0])
	var bb_h: float = float(bbox[3]) - float(bbox[1])
	assert_almost_eq(bb_w, 728.1494, WORLD_EPS, "bbox 世界宽 ≈ 728.149（只圈格心）")
	assert_almost_eq(bb_h, 648.9628, WORLD_EPS, "bbox 世界高 ≈ 648.963")
	# 2026-09-21 贴合化：为消除原版 0.95 收缩留下的缝（2.83% 格宽），poly 统一放大 k≈1.0734
	# ⇒ unit（一格世界尺寸）/ 内切半径 / 视觉包围盒 / 布局指纹**同比放大**，锚点已同步。
	var unit: float = float(_shapes()["unit"])
	assert_almost_eq(unit, 84.5585, WORLD_EPS, "unit = 一个格的世界尺寸（正六边形外径；贴合化后）")
	var seen := {}
	var winding := {}
	var min_apothem := INF
	var hex_radius_max := 0.0
	for c in _cells():
		var cell: Dictionary = c
		var center := _center_of(cell)
		var key := "%.4f,%.4f" % [center.x, center.y]
		assert_false(seen.has(key), "格心 %s 不得与其它格重合" % key)
		seen[key] = true
		# 容差用 WORLD_EPS：center 存的是 32 位浮点（728.1494140625），比 float64 的 bbox 宽
		# 728.1494 略大几个 ulp —— 这不是数据错，是 Vector2 的精度口径（见文件头）。
		assert_between(center.x, -WORLD_EPS, bb_w + WORLD_EPS, "格心 x 应落在 [0, bbox_w] 内（center 已归一化）")
		assert_between(center.y, -WORLD_EPS, bb_h + WORLD_EPS, "格心 y 应落在 [0, bbox_h] 内")
		var poly := _poly_of(cell)
		# 绕序一致（全部同向）：signed area 同号 —— 绕序不一致的多边形混排会让
		# is_point_in_polygon / 顶点内缩等几何判据失真，属于必须暴露的数据问题。
		var s := 0.0
		for i in poly.size():
			var p0: Vector2 = poly[i]
			var p1: Vector2 = poly[(i + 1) % poly.size()]
			s += p0.x * p1.y - p1.x * p0.y
		winding["cw" if s < 0.0 else "ccw"] = true
		# 格心必须**严格落在自格内**（内切圆半径 > 0）：否则内容/命中/高亮全错位。
		var ap := BV.custom_apothem(poly)
		min_apothem = minf(min_apothem, ap)
		assert_gt(ap, 0.0, "格 (%d,%d) 的格心应落在自格内（内切圆半径 %.4f > 0）" % [int(cell["x"]), int(cell["y"]), ap])
		if poly.size() == 6:
			for v in poly:
				hex_radius_max = maxf(hex_radius_max, v.length())
	assert_eq(seen.size(), CELL_COUNT, "211 个格心两两不重合")
	assert_eq(winding.size(), 1, "poly 绕序必须一致（实测集合 = %s）" % str(winding.keys()))
	assert_almost_eq(min_apothem, 14.0601, WORLD_EPS, "最小内切圆半径（五边形）= 14.0601（贴合化后）")
	# unit 的语义自检：六边形顶点到格心的最大距离 = unit/2（外接半径 = 外径/2）
	assert_almost_eq(hex_radius_max, unit * 0.5, WORLD_EPS, "六边形外接半径 = unit/2")


# ==================== ③ 渲染几何层：static 纯函数 ====================

func test_custom_visual_bounds_is_strictly_larger_than_bbox() -> void:
	# 为什么不能拿 bbox 字段当视觉包围盒：它只圈格心，多边形从格心向外伸出一个格半径。
	# 帧口径：bbox 的 position 是**原版世界坐标**（318.93/59.52），而 center 已归一化到 0 起 ⇒
	# 只有 size 可跨帧比较；归一化帧下的格心包围盒恒为 Rect2(0,0,bb.size)。
	var bb := BV.custom_bbox_rect(_shapes()["bbox"])
	var vis := BV.custom_visual_bounds(_cells())
	assert_almost_eq(bb.size.x, 728.1494, WORLD_EPS, "bbox 宽（只圈格心）")
	assert_almost_eq(bb.size.y, 648.9628, WORLD_EPS, "bbox 高（只圈格心）")
	assert_almost_eq(vis.position.x, -25.5109, WORLD_EPS, "视觉左界：最外圈格子向左溢出格心包围盒（贴合化后）")
	assert_almost_eq(vis.position.y, -23.9123, WORLD_EPS, "视觉上界：同上（向上溢出；贴合化后）")
	assert_almost_eq(vis.size.x, 779.1713, WORLD_EPS, "视觉宽（格心 + 顶点并集；贴合化后）")
	assert_almost_eq(vis.size.y, 696.7874, WORLD_EPS, "视觉高（格心 + 顶点并集；贴合化后）")
	assert_gt(vis.size.x, bb.size.x, "视觉宽必须大于格心包围盒宽（多边形外扩）")
	assert_gt(vis.size.y, bb.size.y, "视觉高必须大于格心包围盒高")
	assert_lt(vis.position.x, 0.0, "视觉左界必须为负（格心已归一化到 0 起，多边形的 dx<0 会溢出）")
	assert_lt(vis.position.y, 0.0, "视觉上界必须为负")


func test_custom_layout_scale_to_fit_and_center() -> void:
	var vis := BV.custom_visual_bounds(_cells())
	var unit: float = float(_shapes()["unit"])
	var lay := BV.custom_layout_for(vis, unit, AVAIL_W, AVAIL_H, AVAIL_CENTER)
	var scale: float = lay["scale"]
	var origin: Vector2 = lay["origin"]
	var unit_px: float = lay["unit_px"]
	assert_gt(scale, 0.0, "scale 应为正")
	# ① 等比贴合：视觉包围盒 × scale 恰好贴满某一维（另一维不足）
	var w: float = vis.size.x * scale
	var h: float = vis.size.y * scale
	assert_lte(w, AVAIL_W + WORLD_EPS, "视觉宽不得超出可用宽")
	assert_lte(h, AVAIL_H + WORLD_EPS, "视觉高不得超出可用高")
	assert_almost_eq(maxf(w / AVAIL_W, h / AVAIL_H), 1.0, RATIO_EPS, "应等比贴合（某一维贴满）")
	# ② 居中：视觉包围盒中心对准可用区中心
	var mid := vis.position + vis.size * 0.5
	assert_almost_eq(origin.x + mid.x * scale, AVAIL_CENTER.x, WORLD_EPS, "应水平居中")
	assert_almost_eq(origin.y + mid.y * scale, AVAIL_CENTER.y, WORLD_EPS, "应垂直居中")
	# ③ 口径自洽：unit_px = scale × unit（px / 棋盘单位）
	assert_almost_eq(unit_px, scale * unit, WORLD_EPS, "unit_px 应 = scale × unit")
	assert_almost_eq(float(lay["cell_px"]), BV.CUSTOM_CELL_FRAC * unit_px, 1.0, "cell_px 由密度常量给出")
	# 指纹（默认视口 1280×720）：数字变了 ⇒ 布局口径变了，先确认是不是有意为之
	assert_almost_eq(scale, 0.780726, 1e-5, "scale 指纹（高度受限：544 / 696.7874；贴合化后）")
	assert_almost_eq(unit_px, 66.017, 1e-2, "unit_px 指纹 = scale × unit（贴合化后）")
	assert_eq(int(lay["cell_px"]), 40, "cell_px 指纹（密度旋钮，字号/旗子/雷体都跟它缩放；贴合化后）")
	# ④ 所有格心映射后落在可用区内（任务书要求的判据），且所有多边形顶点也在
	var lo := AVAIL_CENTER - Vector2(AVAIL_W, AVAIL_H) * 0.5
	var hi := AVAIL_CENTER + Vector2(AVAIL_W, AVAIL_H) * 0.5
	var cx_lo := INF
	var cx_hi := -INF
	var cy_lo := INF
	var cy_hi := -INF
	for c in _cells():
		var cell: Dictionary = c
		var center := _center_of(cell)
		var sp := origin + center * scale
		assert_between(sp.x, lo.x, hi.x, "格心映射后 x 应在可用区内")
		assert_between(sp.y, lo.y, hi.y, "格心映射后 y 应在可用区内")
		for v in _poly_of(cell):
			var wp := origin + (center + v) * scale
			cx_lo = minf(cx_lo, wp.x)
			cx_hi = maxf(cx_hi, wp.x)
			cy_lo = minf(cy_lo, wp.y)
			cy_hi = maxf(cy_hi, wp.y)
	assert_gte(cx_lo, lo.x - WORLD_EPS, "多边形顶点不得越出可用区左界")
	assert_lte(cx_hi, hi.x + WORLD_EPS, "多边形顶点不得越出可用区右界")
	assert_gte(cy_lo, lo.y - WORLD_EPS, "多边形顶点不得越出可用区上界")
	assert_lte(cy_hi, hi.y + WORLD_EPS, "多边形顶点不得越出可用区下界")
	# ⑤ 对照：若改用 bbox 字段（只圈格心）做 scale-to-fit，最外圈顶点会被切掉
	var bb := BV.custom_bbox_rect(_shapes()["bbox"])
	var naive: float = minf(AVAIL_W / bb.size.x, AVAIL_H / bb.size.y)
	assert_gt(naive, scale, "bbox 口径算出的 scale 更大（= 盘更大，但会溢出）")
	var naive_origin: Vector2 = AVAIL_CENTER - (bb.size * 0.5) * naive
	var over := 0.0
	for c in _cells():
		var cell: Dictionary = c
		var center := _center_of(cell)
		for v in _poly_of(cell):
			var wp := naive_origin + (center + v) * naive
			over = maxf(over, maxf(maxf(lo.x - wp.x, wp.x - hi.x), maxf(lo.y - wp.y, wp.y - hi.y)))
	assert_gt(over, 0.0, "bbox 口径确实会把多边形顶点推出可用区（这就是不采用它的理由）")
	print("[T-D2 布局] 视觉包围盒=%.2f×%.2f 世界单位  scale=%.5f px/世界单位  unit_px=%.2f  cell_px=%d  "
			% [vis.size.x, vis.size.y, scale, unit_px, int(lay["cell_px"])]
			+ "顶点像素范围=[%.2f,%.2f]×[%.2f,%.2f]  可用区=[%.1f,%.1f]×[%.1f,%.1f]  "
			% [cx_lo, cx_hi, cy_lo, cy_hi, lo.x, hi.x, lo.y, hi.y]
			+ "bbox 口径 scale=%.5f（溢出 %.2fpx）" % [naive, over])


func test_custom_helpers_pure_functions() -> void:
	# custom_apothem：单位正方形（半边长 1）的内切圆半径 = 1
	var sq := PackedVector2Array([Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1), Vector2(1, -1)])
	assert_almost_eq(BV.custom_apothem(sq), 1.0, RATIO_EPS, "正方形内切圆半径 = 半边长")
	assert_eq(BV.custom_apothem(PackedVector2Array([Vector2.ZERO, Vector2.ONE])), 0.0, "少于 3 顶点应返回 0")
	# scale_polygon_about：绕中心等比缩放（shrink=1 原样返回；0.5 半长减半）
	var half := BV.scale_polygon_about(sq, Vector2.ZERO, 0.5)
	assert_eq(half.size(), 4, "顶点数不变")
	for v in half:
		assert_almost_eq(v.length(), sqrt(2.0) * 0.5, RATIO_EPS, "顶点应绕中心收缩到 0.5")
	assert_eq(BV.scale_polygon_about(sq, Vector2.ZERO, 1.0), sq, "shrink=1 应零拷贝返回")
	# custom_point_in_cell：内点/外点
	assert_true(BV.custom_point_in_cell(Vector2(0.5, -0.5), sq), "内点应命中")
	assert_false(BV.custom_point_in_cell(Vector2(2.0, 0.0), sq), "外点不应命中")
	assert_false(BV.custom_point_in_cell(Vector2.ZERO, PackedVector2Array()), "空多边形恒 false")


func test_highlight_points_preserve_index_order() -> void:
	# 「顺序即图案」：hl 是**开放折线**的顶点索引序列，画出来的点必须严格按它取。
	var poly := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	var pts := BV.custom_hl_points(poly, [2, 1, 0], 2.0, Vector2(100.0, 50.0))
	assert_eq(pts.size(), 3, "点数 = hl 长度（开放折线，不闭合、不补首点）")
	assert_almost_eq(pts[0].x, 100.0 + 10.0 * 2.0, WORLD_EPS, "首点应是 poly[2]")
	assert_almost_eq(pts[0].y, 50.0 + 10.0 * 2.0, WORLD_EPS, "首点应是 poly[2]")
	assert_almost_eq(pts[1].x, 100.0 + 10.0 * 2.0, WORLD_EPS, "次点应是 poly[1]")
	assert_almost_eq(pts[2].x, 100.0, WORLD_EPS, "末点应是 poly[0]（顺序倒过来 = 图案镜像，必须按原序）")
	# 反序输入必须给出反序输出（不是「排序后」的序列）
	var rev := BV.custom_hl_points(poly, [0, 1, 2], 2.0, Vector2(100.0, 50.0))
	assert_almost_eq(rev[0].x, 100.0, WORLD_EPS, "hl=[0,1,2] 的首点应是 poly[0]")
	assert_almost_eq(rev[2].x, 120.0, WORLD_EPS, "hl=[0,1,2] 的末点应是 poly[2]")
	# 越界/不足：返回空（整格不画），而不是画一条错的线
	assert_eq(BV.custom_hl_points(poly, [0, 9], 1.0, Vector2.ZERO).size(), 0, "索引越界应返回空")
	assert_eq(BV.custom_hl_points(poly, [0], 1.0, Vector2.ZERO).size(), 0, "hl 少于 2 点应返回空")
	assert_eq(BV.custom_hl_points(PackedVector2Array(), [0, 1], 1.0, Vector2.ZERO).size(), 0, "空多边形应返回空")


func test_every_cell_highlight_is_drawable() -> void:
	# 211 格全部必须能画出高亮折线（没有任何一格因索引越界被静默跳过）——
	# 「静默少画几笔」在截图里极难发现，但那一格的图案就错了。
	var scale := 0.787
	var origin := Vector2(37.0, 11.0)
	var total_pts := 0
	var bad: Array = []
	for c in _cells():
		var cell: Dictionary = c
		var poly := PackedVector2Array()
		var center := _center_of(cell)
		for v in _poly_of(cell):
			poly.append(center + v)
		var pts := BV.custom_hl_points(poly, cell["hl"], scale, origin)
		if pts.size() != (cell["hl"] as Array).size():
			bad.append("%d,%d" % [int(cell["x"]), int(cell["y"])])
		total_pts += pts.size()
	assert_eq(bad, [], "以下格的高亮折线画不出来：%s" % str(bad))
	# 顶点总数复核：31 个六边形 hl 长 4；五边形里 (3,2,1,0) 长 4（30 格），其余 5 种朝向长 3（150 格）
	var want: int = 31 * 4 + 30 * 4 + 150 * 3
	assert_eq(total_pts, want, "折线顶点总数应为 31×4 + 30×4 + 150×3 = %d" % want)


func test_custom_layout_degenerate_inputs() -> void:
	# 退化输入不得崩、不得给出可用的 scale（渲染侧随后回落到 MIN_CELL_PX 下限）。
	assert_eq(int(BV.custom_layout_for(Rect2(Vector2.ZERO, Vector2.ZERO), 78.0, AVAIL_W, AVAIL_H, AVAIL_CENTER)["cell_px"]), 0)
	assert_eq(int(BV.custom_layout_for(Rect2(Vector2.ZERO, Vector2(10, 10)), 0.0, AVAIL_W, AVAIL_H, AVAIL_CENTER)["cell_px"]), 0)
	# 极小可用区：cell_px 必须被 MIN_CELL_PX 抬起来（宁可溢出，也不把格子缩成糊）
	var small := BV.custom_layout_for(Rect2(Vector2.ZERO, Vector2(728.0, 649.0)), 78.7735, 60.0, 60.0, AVAIL_CENTER)
	assert_gte(int(small["cell_px"]), BV.MIN_CELL_PX, "cell_px 不得低于下限")
	assert_almost_eq(float(small["unit_px"]), float(small["cell_px"]) / BV.CUSTOM_CELL_FRAC, WORLD_EPS,
			"下限抬起后 unit_px 与 cell_px 必须同步（否则 scale 与内容密度不一致）")


# ==================== ③ 渲染几何层：board_view 实例接线 ====================

func test_board_view_custom_wiring_and_hit_test() -> void:
	assert_true(GameSession.start_level(LEVEL), "应能开雏菊链（走真实 GameSession 路径）")
	var view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(view)
	await wait_process_frames(1)
	assert_true(view._custom_layout(), "该关应判为自定义多边形盘")
	assert_false(view._hex_layout(), "自定义盘优先于蜂窝判据（两者不同时成立）")
	assert_true(view._custom_layout(), "palette 存在也应仍判为自定义盘")
	var pos := Vector2i(0, 0)
	assert_false(view._custom_cell(pos).is_empty(), "格 (0,0) 应在查表缓存中")
	assert_eq(view._custom_cells.size(), CELL_COUNT, "查表应缓存全部 211 格")
	# 格心 / 顶点：实例换算必须严格等于静态公式（origin + 世界 × scale）
	var cell: Dictionary = view._custom_cell(pos)
	var sc: float = view._custom_scale()
	assert_almost_eq(sc, view._custom_unit_px / view._custom_unit_world(), RATIO_EPS, "scale = unit_px / unit")
	assert_almost_eq(view._cell_center(pos).x, view.board_origin.x + float(cell["center"][0]) * sc, WORLD_EPS,
			"格心 x = origin + center.x × scale")
	assert_almost_eq(view._cell_center(pos).y, view.board_origin.y + float(cell["center"][1]) * sc, WORLD_EPS,
			"格心 y = origin + center.y × scale")
	var poly: PackedVector2Array = view._cell_polygon(pos)
	assert_eq(poly.size(), (cell["rel"] as PackedVector2Array).size(),
			"多边形顶点数必须与数据一致（%d）" % (cell["rel"] as PackedVector2Array).size())
	for i in poly.size():
		var want: Vector2 = view.board_origin + (cell["poly"] as PackedVector2Array)[i] * sc
		assert_almost_eq(poly[i].x, want.x, WORLD_EPS, "顶点 x = origin + 世界顶点 × scale")
		assert_almost_eq(poly[i].y, want.y, WORLD_EPS, "顶点 y = origin + 世界顶点 × scale")
	# 外接矩形（_cell_rect）应恰好包住多边形
	var rect: Rect2 = view._cell_rect(pos)
	for v in poly:
		assert_true(rect.has_point(v) or _on_edge(rect, v), "外接矩形应包住多边形顶点")
	# 命中测试：格心必中自身
	assert_eq(view._pick(view._cell_center(pos)), pos, "格心必命中自身")
	# 互不命中：A 的格心不得落在 B 的多边形内（抽前 12 格两两互查）
	var sample: Array = []
	for i in mini(12, view._custom_cells.size()):
		sample.append((GameSession.board.grid.all_positions() as Array)[i])
	for a: Vector2i in sample:
		for b: Vector2i in sample:
			if a == b:
				continue
			assert_false(BV.custom_point_in_cell(view._cell_center(a), view._cell_polygon(b)),
					"格 (%d,%d) 的格心不得落在格 (%d,%d) 的多边形内" % [a.x, a.y, b.x, b.y])
			assert_ne(view._pick(view._cell_center(a)), b, "格心不得被拾取为邻格")
	# 盘外四角（视觉包围盒的四个角，远离所有格）不得命中任何格
	var vis := BV.custom_visual_bounds(_cells())
	for corner in [vis.position, vis.position + Vector2(vis.size.x, 0.0), vis.position + Vector2(0.0, vis.size.y), vis.position + vis.size]:
		var sp: Vector2 = view.board_origin + corner * sc
		assert_eq(view._pick(sp), Vector2i(-1, -1), "盘外角 %s 不应命中任何格" % str(corner))
	# 绘画层换算：棋盘坐标 = 世界 / unit，两者必须严格互补（往返误差 < 1e-3）
	for bp in [Vector2(3.25, 4.75), Vector2(0.0, 0.0), Vector2(9.0, 8.0)]:
		var back: Vector2 = view._screen_pt_to_board(view._board_pt_to_screen(bp))
		assert_almost_eq(back.x, bp.x, 1e-3, "自定义盘换算 x 应可逆")
		assert_almost_eq(back.y, bp.y, 1e-3, "自定义盘换算 y 应可逆")
	# 棋盘坐标口径：格心 / unit 应映射回格心的屏幕坐标（笔记与格子对齐的关键）
	var center_bp: Vector2 = Vector2(cell["center"]) / view._custom_unit_world()
	assert_almost_eq(view._board_pt_to_screen(center_bp).x, view._cell_center(pos).x, WORLD_EPS,
			"棋盘坐标 = 世界 / unit ⇒ 格心应映射回自己")
	assert_almost_eq(view._board_pt_to_screen(center_bp).y, view._cell_center(pos).y, WORLD_EPS, "同上（y）")
	# 高亮折线：实例算出的屏幕序列必须严格等于「世界顶点 × scale + origin」按 hl 索引取——
	# 这条覆盖了「查表 → 索引序 → 屏幕」的完整管线（花纹画错的第一嫌疑人）。
	for key: Vector2i in [Vector2i(0, 0), Vector2i(13, 9), Vector2i(5, 8)]:
		var cd: Dictionary = view._custom_cell(key)
		var want_pts := BV.custom_hl_points(cd["poly"], cd["hl"], view._custom_scale(), view.board_origin)
		assert_eq(want_pts.size(), (cd["hl"] as Array).size(), "高亮折线点数 = hl 长度 (%d,%d)" % [key.x, key.y])
		for i in want_pts.size():
			var idx: int = int((cd["hl"] as Array)[i])
			var ref: Vector2 = view.board_origin + (cd["poly"] as PackedVector2Array)[idx] * view._custom_scale()
			assert_almost_eq(want_pts[i].x, ref.x, WORLD_EPS, "hl[%d] 应取 poly[%d]" % [i, idx])
			assert_almost_eq(want_pts[i].y, ref.y, WORLD_EPS, "hl[%d] 应取 poly[%d]（y）" % [i, idx])
	# 几何摘要：与离线复算（tools 侧脚本/Python）交叉核对，确保「离线预览图 == 本渲染管线」。
	# 这些是**屏幕坐标**的逐格累加和，口径 = 本文件头写的三段映射；数字对得上 ⇒ 预览图有效。
	var poly_sum := Vector2.ZERO
	var hl_sum := Vector2.ZERO
	for p: Vector2i in GameSession.board.grid.all_positions():
		for v in view._cell_polygon(p):
			poly_sum += v
		var cd2: Dictionary = view._custom_cell(p)
		for v in BV.custom_hl_points(cd2["poly"], cd2["hl"], view._custom_scale(), view.board_origin):
			hl_sum += v
	print("[T-D2 几何摘要] scale=%.6f origin=(%.4f,%.4f) cell_px=%d 多边形顶点和=(%.3f,%.3f) 高亮折线点和=(%.3f,%.3f)"
			% [view._custom_scale(), view.board_origin.x, view.board_origin.y, view.cell_px,
			poly_sum.x, poly_sum.y, hl_sum.x, hl_sum.y])
	GameSession.start_level(CLASSIC)   # 复位全局盘面，避免污染后续测试


func test_board_view_rect_path_still_has_no_custom_branch() -> void:
	# 零回归：经典关卡上自定义分支必须完全关闭（palette/多边形几何一律不参与）。
	assert_true(GameSession.start_level(CLASSIC), "需要经典矩形关卡")
	assert_false(GameSession.board.has_meta("custom_shapes"), "经典关卡不得有 custom_shapes meta")
	var view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(view)
	await wait_process_frames(1)
	assert_false(view._custom_layout(), "经典关卡不得判为自定义盘")
	assert_false(view._hex_layout(), "经典关卡不得判为蜂窝")
	assert_true(view._custom_palette().is_empty(), "无 palette ⇒ 取色全部回退主题色")
	assert_eq(view._cell_rect(Vector2i(3, 4)),
			Rect2(view.board_origin + Vector2(3, 4) * view.cell_px, Vector2(view.cell_px, view.cell_px)),
			"矩形路径格位矩形必须与原式逐像素一致")
	assert_eq(view._cell_polygon(Vector2i(3, 4)).size(), 4, "矩形格轮廓仍为 4 顶点")


## 点是否落在矩形边界上（Rect2.has_point 右/下边界为开区间，需单独放行）。
func _on_edge(r: Rect2, p: Vector2) -> bool:
	return is_equal_approx(p.x, r.position.x) or is_equal_approx(p.y, r.position.y) \
			or is_equal_approx(p.x, r.position.x + r.size.x) or is_equal_approx(p.y, r.position.y + r.size.y)
