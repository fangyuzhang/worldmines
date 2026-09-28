# test_shape_style.gd —— T4：几何风格贯通（core）+ 蜂窝六边形几何（ui）
#
# 三条链，一一对应本次交付：
#   ① 风格贯通：ShapeGenerator 三族产出 style/params → AdjacencyGrid.setup_from_topo 读出
#      → PuzzleGenerator._topology_to_dict 落盘 → Board.load_level 重建后 style 仍在；
#      无 style 的旧拓扑 → "custom"（= 按包围盒方阵渲染，向后兼容）。
#   ② 蜂窝几何：格心 = 0.75*(x+y) / (√3/4)*(x−y)（斜交晶格）、相邻格心距 = √3/2、
#      6 顶点距格心 = 外接半径 0.475、内切半径 = (√3/2)R ≈ 0.4114
#      ⇒ 两格内切半径和 0.823 < 格心距 0.866（留 ~5% 缝：原版 0.95 收缩的复刻，勿改）。
#   ③ 关卡产物：res://levels/hex_01..03.json 的 topology 带 "style":"hex"
#      （渲染层据此按六边形排布；挖洞方格族带 style 但不是 hex ⇒ 仍走方阵）。
#
# 几何断言打在 ui/board_view.gd 的 **static 纯函数**上（hex_center_lattice / hex_vertex_units /
# hex_layout_for / hex_polygon_px）——不实例化场景、不依赖视口，确定性可复现；最后两条实例化
# board_view 验「接线」：实例换算 == 同一份 static 公式、命中测试取最近格心、矩形路径逐像素不变。
#
# ⚠️ 精度口径：Godot 的 Vector2 分量是 **32 位浮点**（real_t），凡经过 Vector2 的几何量都只有
#    ~1e-7 的相对精度（0.866025388 vs 0.86602540378 就是这么来的）。故：
#    晶格量（~1 量级）用 LATTICE_EPS，像素量（~100 量级）用 PX_EPS；只有纯 float64 常量恒等式
#    才用 1e-12。写 1e-9 比较 Vector2 是自欺（首跑实测）。这些容差都远小于「半个像素」，
#    不影响任何断言的实际约束力。
extends GutTest

## board_view 脚本本体（取 static 纯函数与常量；它没有 class_name，故 load 后用）。
const BV := preload("res://ui/board_view.gd")
const LATTICE_EPS := 1e-5    # 晶格单位（~1 量级）的 Vector2 比较容差
const PX_EPS := 1e-2         # 像素（~100 量级）的 Vector2 比较容差
const EXACT_EPS := 1e-12     # 纯 float64 常量恒等式

const HEX_LEVELS: Array = ["res://levels/hex_01.json", "res://levels/hex_02.json", "res://levels/hex_03.json"]
## 关卡文件名 → 蜂窝 size（与 tools/gen_shape_levels.gd:SPECS 同源，独立抄写便于互相核对）。
const HEX_SIZE_OF := {"hex_01.json": 5, "hex_02.json": 7, "hex_03.json": 9}
const HOLED_LEVELS: Array = ["res://levels/holed_01.json", "res://levels/holed_02.json", "res://levels/holed_03.json"]
## 默认视口的可用区（1280×720；左右各 24、上 HUD 64 + 24、下 24 + 底栏 64）。
## 注：2026-09-28 起 board_view._layout 还会再扣除 HUD 左右侧列（2×HUD_SIDE_RESERVE），
## 实际可用宽 < 1232 —— 本文件测的是**纯函数**（avail 由调用方给定），故用旧口径常量即可；
## 端到端布局的守卫在 test/ui/test_ui_rework_contract.gd。
const AVAIL_W := 1232.0
const AVAIL_H := 544.0
const AVAIL_CENTER := Vector2(640.0, 64.0 + 272.0)


# ==================== 工具 ====================

## 蜂窝盘的全部格坐标（可直接喂给 static 几何函数）。
func _hex_positions(size: int) -> Array:
	var out: Array = []
	for p in _hex_grid(size).all_positions():
		out.append(p)
	return out


func _hex_grid(size: int) -> AdjacencyGrid:
	return ShapeGenerator.to_adjacency_grid("hex", {"size": size})


## 最小可读的旧式拓扑（无 style / params 字段）。
func _legacy_topo() -> Dictionary:
	return {
		"positions": [{"x": 0, "y": 0}, {"x": 1, "y": 0}],
		"adjacency": [{"a": {"x": 0, "y": 0}, "b": {"x": 1, "y": 0}}],
	}


func _json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


# ==================== ① 风格贯通（core） ====================

func test_shape_generator_emits_style_fields() -> void:
	var h := ShapeGenerator.build_hex(5)
	assert_eq(h.get("style", ""), "hex", "build_hex 应标 style=hex")
	assert_eq(int((h.get("params", {}) as Dictionary).get("size", -1)), 5, "build_hex 应带 params.size=5")
	var holed := ShapeGenerator.build_holed_grid(3, 3, [Vector2i(1, 1)])
	assert_eq(holed.get("style", ""), "holed_grid", "build_holed_grid 应标 style=holed_grid")
	var t := ShapeGenerator.build_t488(2)
	assert_eq(t.get("style", ""), "t488", "build_t488 应标 style=t488")
	assert_eq(int((t.get("params", {}) as Dictionary).get("size", -1)), 2, "build_t488 应带 params.size=2")
	# 风格是**纯追加**：拓扑数据本身一个字都没变（hex(5) = 19 格 / 42 边）
	assert_eq((h["positions"] as Array).size(), 19, "风格字段不得改动拓扑：hex(5) 仍是 19 格")
	assert_eq((h["adjacency"] as Array).size(), 42, "风格字段不得改动拓扑：hex(5) 仍是 42 边")


func test_setup_from_topo_reads_style_and_params() -> void:
	var g := AdjacencyGrid.new()
	g.setup_from_topo(ShapeGenerator.build_hex(3))
	assert_eq(g.style, "hex", "邻接表应读出 style")
	assert_eq(int(g.style_params.get("size", -1)), 3, "邻接表应读出 params.size")
	assert_true(g.has_hex_layout(), "style==hex ⇒ has_hex_layout() 为真")
	assert_eq(g.cell_count(), 7, "读风格不影响拓扑（hex(3) = 7 格）")


func test_legacy_topo_without_style_is_custom() -> void:
	# 向后兼容：旧关卡/手写拓扑没有 style 字段 ⇒ "custom" ⇒ 渲染按包围盒方阵（行为零变化）。
	var g := AdjacencyGrid.new()
	g.setup_from_topo(_legacy_topo())
	assert_eq(g.style, "custom", "无 style 的旧拓扑应为 custom")
	assert_true(g.style_params.is_empty(), "无 params 的旧拓扑应给空字典")
	assert_false(g.has_hex_layout(), "custom 不得被判成蜂窝")
	assert_eq(g.cell_count(), 2, "旧拓扑照常构建")


func test_normalized_keeps_style() -> void:
	# 坐标归一化（CP-SAT 非负化）会新建实例：风格必须跟着走，否则蜂窝盘会被静默降级成方阵。
	var moved := AdjacencyGrid.new()
	moved.setup_from_topo({
		"positions": [{"x": -1, "y": -1}, {"x": 0, "y": -1}],
		"adjacency": [{"a": {"x": -1, "y": -1}, "b": {"x": 0, "y": -1}}],
		"style": "hex", "params": {"size": 3},
	})
	var norm := AdjacencyGrid.normalized(moved)
	assert_eq(norm.style, "hex", "归一化后 style 应保留")
	assert_eq(int(norm.style_params.get("size", -1)), 3, "归一化后 params.size 应保留")
	assert_eq(norm.all_positions()[0], Vector2i(0, 0), "归一化仍把坐标挪到非负")
	# 坐标本就非负（工具链常态）→ 原实例返回，风格自然不丢
	var same := _hex_grid(5)
	assert_true(AdjacencyGrid.normalized(same) == same, "非负坐标应零拷贝返回原实例")


func test_topology_to_dict_writes_style_when_styled() -> void:
	var d := PuzzleGenerator._topology_to_dict(_hex_grid(5))
	assert_eq(d.get("style", ""), "hex", "带风格的邻接表应把 style 落盘")
	assert_eq(int((d.get("params", {}) as Dictionary).get("size", -1)), 5, "params.size 应一并落盘")
	assert_eq((d["positions"] as Array).size(), 19, "落盘拓扑 positions 不变")
	assert_eq((d["adjacency"] as Array).size(), 42, "落盘拓扑边数不变")


func test_topology_to_dict_unchanged_for_rect_and_custom() -> void:
	# 零变化约束：矩形关卡与无风格的旧异形拓扑，落盘格式**逐键不变**（不凭空多出 style/params）。
	var rg := RectGrid.new()
	rg.setup(5, 4)
	var rd := PuzzleGenerator._topology_to_dict(rg)
	assert_false(rd.has("style"), "矩形关卡落盘不得新增 style（既有矩形关卡 JSON 零变化）")
	assert_false(rd.has("params"), "矩形关卡落盘不得新增 params")
	assert_true(rd.has("positions") and rd.has("adjacency"), "原有字段照旧")
	var custom := AdjacencyGrid.new()
	custom.setup_from_topo(_legacy_topo())
	assert_eq(custom.style, "custom", "前提：旧拓扑 style=custom")
	var cd := PuzzleGenerator._topology_to_dict(custom)
	assert_false(cd.has("style"), "style==custom 时不得写 style 字段")
	assert_false(cd.has("params"), "style==custom 时不得写 params 字段")


func test_topology_json_roundtrip_keeps_style() -> void:
	# 「落盘 → 读回」的真往返（JSON.stringify 与 FileAccess 写盘同一编码路径）。
	var d := PuzzleGenerator._topology_to_dict(_hex_grid(7))
	var parsed: Variant = JSON.parse_string(JSON.stringify(d, "  "))
	assert_true(parsed is Dictionary, "落盘产物应是合法 JSON 对象")
	if not parsed is Dictionary:
		return
	var back := AdjacencyGrid.new()
	back.setup_from_topo(parsed)
	assert_eq(back.style, "hex", "JSON 往返后 style 仍在")
	assert_eq(int(back.style_params.get("size", -1)), 7, "JSON 往返后 params.size 仍在")
	assert_true(back.has_hex_layout(), "往返后仍是蜂窝几何")
	assert_eq(back.cell_count(), 37, "往返后拓扑不丢格（hex(7) = 37）")


func test_generate_with_rules_roundtrip_keeps_hex_style() -> void:
	# 端到端：真实生成产物 → JSON 往返 → Board.load_level 重建（与 tools/gen_shape_levels.gd 同参数）。
	var g := _hex_grid(5)
	var gen := PuzzleGenerator.new()
	var level: Dictionary = gen.generate_with_rules("classic", [], g.size(), 4, 4001, 0, 50, g)
	assert_false(level.is_empty(), "hex(5)/4 雷/seed 4001 应能生成（与 gen_shape_levels.gd:SPECS 同参数）")
	if level.is_empty():
		return
	var topo: Dictionary = level.get("topology", {})
	assert_eq(topo.get("style", ""), "hex", "生成产物落盘的拓扑应带 style")
	assert_eq(int((topo.get("params", {}) as Dictionary).get("size", -1)), 5, "生成产物落盘的拓扑应带 params.size")
	var parsed: Variant = JSON.parse_string(JSON.stringify(level))
	assert_true(parsed is Dictionary, "生成产物应可 JSON 序列化（落盘前提）")
	if not parsed is Dictionary:
		return
	var b := Board.new()
	b.load_level(parsed)
	assert_true(b.grid is AdjacencyGrid, "载回后应是异形棋盘")
	assert_eq(b.grid.style, "hex", "载回后仍是蜂窝几何（渲染层的判据）")
	assert_true(b.grid.has_hex_layout(), "载回后 has_hex_layout() 为真")
	assert_eq(b.grid.cell_count(), 19, "载回后格数不变")


func test_hex_levels_carry_hex_style_on_disk() -> void:
	for path in HEX_LEVELS:
		if not FileAccess.file_exists(path):
			pending("缺少 %s —— 先跑 tools/gen_shape_levels.gd" % path)
			continue
		var b: Board = LevelLoader.load_level(path)
		assert_not_null(b, "%s 应能载入" % path)
		if b == null:
			continue
		assert_true(b.grid is AdjacencyGrid, "%s 应是异形棋盘" % path)
		assert_eq(b.grid.style, "hex", "%s 应带 style=hex（渲染层据此走六边形排布）" % path)
		assert_true(b.grid.has_hex_layout(), "%s 应判为蜂窝几何" % path)
		var want := int(HEX_SIZE_OF[path.get_file()])
		assert_eq(int(b.grid.style_params.get("size", 0)), want, "%s params.size 应等于规格 size" % path)


func test_hex_levels_json_topology_has_style() -> void:
	# 直接读 JSON 原文：防止「只有 loader 会补字段」的错觉（style 必须真的在文件里）。
	for path in HEX_LEVELS:
		if not FileAccess.file_exists(path):
			pending("缺少 %s —— 先跑 tools/gen_shape_levels.gd" % path)
			continue
		var topo: Dictionary = _json(path).get("topology", {})
		assert_eq(topo.get("style", ""), "hex", "%s 的 topology.style 应为 hex" % path)
		assert_eq(int((topo.get("params", {}) as Dictionary).get("size", 0)), int(HEX_SIZE_OF[path.get_file()]),
				"%s 的 topology.params.size 应与规格一致" % path)


func test_holed_levels_are_styled_but_not_hex() -> void:
	# 挖洞方格族也要有 style（工具重生成后），但**不是**蜂窝 ⇒ 渲染仍走包围盒方阵。
	for path in HOLED_LEVELS:
		if not FileAccess.file_exists(path):
			pending("缺少 %s —— 先跑 tools/gen_shape_levels.gd" % path)
			continue
		var b: Board = LevelLoader.load_level(path)
		assert_not_null(b, "%s 应能载入" % path)
		if b == null:
			continue
		assert_eq(b.grid.style, "holed_grid", "%s 应带 style=holed_grid" % path)
		assert_false(b.grid.has_hex_layout(), "%s 不是蜂窝：不得走六边形几何" % path)


# ==================== ② 蜂窝几何（static 纯函数） ====================

func test_hex_center_lattice_formula() -> void:
	# 格心公式（原版字节码）：cx = 0.75*(x+y)、cy = (√3/4)*(x−y)。
	assert_almost_eq(BV.hex_center_lattice(Vector2i(0, 0)).x, 0.0, LATTICE_EPS)
	assert_almost_eq(BV.hex_center_lattice(Vector2i(0, 0)).y, 0.0, LATTICE_EPS)
	assert_almost_eq(BV.hex_center_lattice(Vector2i(1, 0)).x, 0.75, LATTICE_EPS, "(1,0) 的 cx 步长 = 0.75")
	assert_almost_eq(BV.hex_center_lattice(Vector2i(1, 0)).y, BV.HEX_CY, LATTICE_EPS, "(1,0) 的 cy = (√3/4)")
	assert_almost_eq(BV.hex_center_lattice(Vector2i(0, 1)).x, 0.75, LATTICE_EPS, "(0,1) 与 (1,0) 在 cx 上同向")
	assert_almost_eq(BV.hex_center_lattice(Vector2i(0, 1)).y, -BV.HEX_CY, LATTICE_EPS, "而 cy 反向")
	var c := BV.hex_center_lattice(Vector2i(2, 3))
	assert_almost_eq(c.x, 0.75 * 5.0, LATTICE_EPS, "cx = 0.75*(2+3)")
	assert_almost_eq(c.y, -BV.HEX_CY, LATTICE_EPS, "cy = (√3/4)*(2−3)")
	assert_almost_eq(BV.HEX_CY, sqrt(3.0) / 4.0, EXACT_EPS, "HEX_CY == √3/4")
	# 格心 → 像素：origin + 晶格 × unit（仿射，与矩形路径同构）
	var px := BV.hex_center_px(Vector2i(2, 3), 100.0, Vector2(7.0, -3.0))
	assert_almost_eq(px.x, 7.0 + 3.75 * 100.0, PX_EPS, "像素格心 x")
	assert_almost_eq(px.y, -3.0 - BV.HEX_CY * 100.0, PX_EPS, "像素格心 y")


func test_hex_neighbor_distance_is_sqrt3_over_2() -> void:
	# 最强几何–拓扑一致性断言：**邻接 ⟺ 格心距恰为 √3/2**（6 个邻方向等距，斜交晶格的特征）。
	assert_almost_eq(BV.HEX_SPACING, sqrt(3.0) / 2.0, EXACT_EPS, "相邻格心距 = √3/2 ≈ 0.866")
	# 有向邻接数 = 无向边 × 2（size=5 的 42 边 → 84；各 size 的数字与 test_shape_levels.gd 的边数互为独立核对）
	var want_directed := {3: 24, 5: 84, 7: 180, 9: 312}
	for n in [3, 5, 7, 9]:
		var g := _hex_grid(n)
		var checked := 0
		for p in g.all_positions():
			for nb in g.get_neighbors(p):
				var d := BV.hex_center_lattice(p).distance_to(BV.hex_center_lattice(nb))
				assert_almost_eq(d, BV.HEX_SPACING, LATTICE_EPS,
						"size=%d 邻格 (%d,%d)-(%d,%d) 的格心距应为 √3/2" % [n, p.x, p.y, nb.x, nb.y])
				checked += 1
		assert_eq(checked, int(want_directed[n]),
				"size=%d 应有 %d 条有向邻接（形状若变了这里会先红灯）" % [n, int(want_directed[n])])


func test_hex_non_neighbors_are_at_least_1_5_apart() -> void:
	# 非邻格最近距 = 1.5（= 0.866×√3）> 两格内切半径和 0.823 ⇒ 非邻格的六边形绝不相交。
	var g := _hex_grid(5)
	var pair := {}
	for p in g.all_positions():
		for nb in g.get_neighbors(p):
			pair["%d,%d|%d,%d" % [p.x, p.y, nb.x, nb.y]] = true
			pair["%d,%d|%d,%d" % [nb.x, nb.y, p.x, p.y]] = true
	var min_gap := INF
	for a in g.all_positions():
		for b in g.all_positions():
			if a == b or pair.has("%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]):
				continue
			min_gap = minf(min_gap, BV.hex_center_lattice(a).distance_to(BV.hex_center_lattice(b)))
	assert_almost_eq(min_gap, 1.5, LATTICE_EPS, "非邻格最近距应为 1.5（0.866×√3）")
	assert_gt(min_gap, 2.0 * BV.HEX_INRADIUS, "非邻格距必须大于两格内切半径和（否则六边形会相交）")


func test_hex_row_span_fingerprint() -> void:
	# 逐行跨度：第 r 行有 n_r 格、x 连续取值 ⇒ cx 跨度 = 0.75*(n_r−1)、cy 跨度 = (√3/4)*(n_r−1)。
	var g := _hex_grid(5)
	var want_rows := [3, 4, 5, 4, 3]   # 与 test_shape_levels.gd 的 row_lens 指纹同源
	for r in 5:
		var cxs: Array = []
		var cys: Array = []
		for p in g.all_positions():
			if p.y == r:
				var c := BV.hex_center_lattice(p)
				cxs.append(c.x)
				cys.append(c.y)
		assert_eq(cxs.size(), int(want_rows[r]), "hex(5) 第 %d 行格数应为 %d" % [r, int(want_rows[r])])
		assert_almost_eq(float(cxs.max()) - float(cxs.min()), 0.75 * float(cxs.size() - 1), LATTICE_EPS,
				"第 %d 行 cx 跨度" % r)
		assert_almost_eq(float(cys.max()) - float(cys.min()), BV.HEX_CY * float(cys.size() - 1), LATTICE_EPS,
				"第 %d 行 cy 跨度" % r)
	# 整体格心包围盒（hex(5)）：cx ∈ [1.5, 4.5]、cy 跨度 = 4×√3/2 = 3.4641016
	var b := BV.hex_lattice_bounds(_hex_positions(5))
	assert_almost_eq(b.position.x, 1.5, LATTICE_EPS, "hex(5) 格心最小 cx = 0.75*(0+2)")
	assert_almost_eq(b.size.x, 3.0, LATTICE_EPS, "hex(5) 格心 cx 跨度 = 3.0")
	assert_almost_eq(b.size.y, 4.0 * BV.HEX_SPACING, LATTICE_EPS, "hex(5) 格心 cy 跨度 = 4×√3/2")


func test_hex_vertex_units_and_inradius() -> void:
	var vs := BV.hex_vertex_units()
	assert_eq(vs.size(), 6, "六边形应有 6 个顶点")
	for v in vs:
		assert_almost_eq(v.length(), BV.HEX_R, LATTICE_EPS, "顶点距格心 = 外接半径 R = 0.475")
	for i in vs.size():
		var nxt: Vector2 = vs[(i + 1) % vs.size()]
		assert_almost_eq(vs[i].distance_to(nxt), BV.HEX_R, LATTICE_EPS, "相邻顶点距（边长）= R")
		var mid: Vector2 = (vs[i] + nxt) * 0.5
		assert_almost_eq(mid.length(), BV.HEX_INRADIUS, LATTICE_EPS, "边中点到格心 = 内切半径")
	assert_almost_eq(BV.HEX_INRADIUS, sqrt(3.0) / 2.0 * BV.HEX_R, EXACT_EPS, "内切半径 = (√3/2)R")
	# ~5% 缝（原版 0.95 收缩的复刻）：两格内切半径和 < 相邻格心距
	assert_almost_eq(2.0 * BV.HEX_INRADIUS, 0.8227241335952166, EXACT_EPS, "两格内切半径和 ≈ 0.823")
	assert_lt(2.0 * BV.HEX_INRADIUS, BV.HEX_SPACING, "相邻六边形之间必须留缝（0.823 < 0.866）")
	assert_almost_eq((BV.HEX_SPACING - 2.0 * BV.HEX_INRADIUS) / BV.HEX_SPACING, 0.05, EXACT_EPS, "缝宽 ≈ 5%")


func test_hex_inner_square_fits_inside_hexagon() -> void:
	# 渲染用「内接正方形」的半边长必须真的内接：否则正方形四角越出六边形，还会压到邻格。
	var s := BV.HEX_SQ_HALF
	for sx in [s, -s]:
		for sy in [s, -s]:
			# 平顶六边形：斜边约束 |x| ≤ R − |y|/√3；上下水平边约束 |y| ≤ (√3/2)R
			assert_lte(absf(sx), BV.HEX_R - absf(sy) / BV.HEX_SQ3 + EXACT_EPS, "内接正方形角点须落在斜边内侧")
			assert_lte(absf(sy), BV.HEX_SPACING * BV.HEX_R + EXACT_EPS, "内接正方形角点须落在水平边内侧")
	assert_almost_eq(s, BV.HEX_R / (1.0 + 1.0 / BV.HEX_SQ3), EXACT_EPS, "半边长 = R/(1+1/√3) = 0.3011379…")
	assert_almost_eq(s, BV.HEX_R - s / BV.HEX_SQ3, EXACT_EPS, "角点恰好落在斜边上 = 最大内接正方形")
	# 对照（这就是不采用「半边长 = 内切半径」的原因）：0.4114 > R − 0.4114/√3 ⇒ 越出六边形
	var bad := BV.HEX_INRADIUS
	assert_gt(absf(bad), BV.HEX_R - absf(bad) / BV.HEX_SQ3,
			"半边长取内切半径会越出斜边（正方形角点会露在六边形外并压到邻格）")


func test_hex_inner_squares_do_not_overlap() -> void:
	# 零重叠判据（等大半边长正方形）：|Δx| ≥ 2s 或 |Δy| ≥ 2s。s = HEX_SQ_HALF 时 6 个邻方向全部满足。
	var side := 2.0 * BV.HEX_SQ_HALF
	assert_lt(side, BV.HEX_SPACING, "内接正方形边长必须小于相邻格心距")
	var g := _hex_grid(5)
	for p in g.all_positions():
		for nb in g.get_neighbors(p):
			var d: Vector2 = (BV.hex_center_lattice(nb) - BV.hex_center_lattice(p)).abs()
			assert_true(d.x >= side - LATTICE_EPS or d.y >= side - LATTICE_EPS,
					"相邻格 (%d,%d)-(%d,%d) 的内接正方形不得重叠（Δ=(%.3f,%.3f)，边长 %.3f）"
							% [p.x, p.y, nb.x, nb.y, d.x, d.y, side])


func test_hex_polygon_px_vertices_and_shrink() -> void:
	var unit := 100.0
	var origin := Vector2(37.0, 11.0)
	var pos := Vector2i(2, 3)
	var poly := BV.hex_polygon_px(pos, unit, origin)
	assert_eq(poly.size(), 6, "格轮廓应是 6 顶点")
	var c := BV.hex_center_px(pos, unit, origin)
	for v in poly:
		assert_almost_eq(v.distance_to(c), BV.HEX_R * unit, PX_EPS, "顶点距格心 = 0.475×unit_px")
	# 相邻格心距（像素）= √3/2 × unit_px
	var d := BV.hex_center_px(Vector2i(1, 0), unit, origin).distance_to(BV.hex_center_px(Vector2i(0, 0), unit, origin))
	assert_almost_eq(d, BV.HEX_SPACING * unit, PX_EPS, "相邻格心距（像素）= √3/2×unit_px")
	# shrink：绕格心等比收缩（wave / pop 的收缩比直接喂进来，动效状态机一行未改）
	var shr := BV.hex_polygon_px(pos, unit, origin, 0.86)
	assert_eq(shr.size(), 6, "收缩后仍是 6 顶点")
	for i in shr.size():
		assert_almost_eq(shr[i].distance_to(c), BV.HEX_R * unit * 0.86, PX_EPS, "shrink=0.86 应绕格心收缩到 0.86")
		# 纯径向缩放：方位不变（仍落在「格心 → 原顶点」这条射线上）
		var ray := c + (poly[i] - c) * 0.86
		assert_almost_eq(shr[i].distance_to(ray), 0.0, PX_EPS, "顶点应沿径向下移（不改方位）")


func test_hex_layout_scale_to_fit_and_center() -> void:
	# 默认视口 1280×720（可用区 1232×544）：断言**不变量**（等比贴合 + 居中 + 按实际跨度而非包围盒）。
	for n in [5, 7, 9]:
		var pos := _hex_positions(n)
		var lay := BV.hex_layout_for(pos, AVAIL_W, AVAIL_H, AVAIL_CENTER)
		var unit: float = lay["unit_px"]
		var span: Vector2 = lay["span"]
		var origin: Vector2 = lay["origin"]
		assert_gt(unit, 0.0, "size=%d unit_px 应为正" % n)
		var w: float = span.x * unit
		var h: float = span.y * unit
		assert_lte(w, AVAIL_W + PX_EPS, "size=%d 视觉宽不得超出可用宽" % n)
		assert_lte(h, AVAIL_H + PX_EPS, "size=%d 视觉高不得超出可用高" % n)
		assert_almost_eq(maxf(w / AVAIL_W, h / AVAIL_H), 1.0, 1e-6, "size=%d 应等比贴合（某一维贴满）" % n)
		var b := BV.hex_lattice_bounds(pos)
		var vis := origin + (b.position + b.size * 0.5) * unit
		assert_almost_eq(vis.x, AVAIL_CENTER.x, PX_EPS, "size=%d 应水平居中" % n)
		assert_almost_eq(vis.y, AVAIL_CENTER.y, PX_EPS, "size=%d 应垂直居中" % n)
		assert_eq(int(lay["cell_px"]), int(round(2.0 * BV.HEX_SQ_HALF * unit)), "cell_px = 内接正方形边长")
		# 视觉跨度必须窄于 size×size 包围盒（否则等于没按六边形几何量）
		assert_lt(span.x, float(n), "size=%d 视觉宽应窄于包围盒宽" % n)
		assert_lt(span.y, float(n), "size=%d 视觉高应窄于包围盒高" % n)
		# ★ 直接量「所有六边形顶点」的包围盒（而不是只信 hex_visual_span 的公式）：它必须
		#   (a) 与算出的 span 一致、(b) 整个落在可用区内。这条能抓住「上下只外扩 R 而不是半高」
		#   这类公式错误（首跑就是靠打印的像素数发现的：最上/最下两排会被切掉半个高度）。
		var pmin := Vector2(INF, INF)
		var pmax := Vector2(-INF, -INF)
		for p in pos:
			for v in BV.hex_polygon_px(p, unit, origin):
				pmin = Vector2(minf(pmin.x, v.x), minf(pmin.y, v.y))
				pmax = Vector2(maxf(pmax.x, v.x), maxf(pmax.y, v.y))
		assert_almost_eq(pmax.x - pmin.x, w, PX_EPS, "size=%d 实际顶点包围盒宽应等于 span 宽" % n)
		assert_almost_eq(pmax.y - pmin.y, h, PX_EPS, "size=%d 实际顶点包围盒高应等于 span 高" % n)
		assert_gte(pmin.x, AVAIL_CENTER.x - AVAIL_W * 0.5 - PX_EPS, "size=%d 顶点不得越出可用区左界" % n)
		assert_lte(pmax.x, AVAIL_CENTER.x + AVAIL_W * 0.5 + PX_EPS, "size=%d 顶点不得越出可用区右界" % n)
		assert_gte(pmin.y, AVAIL_CENTER.y - AVAIL_H * 0.5 - PX_EPS, "size=%d 顶点不得越出可用区上界" % n)
		assert_lte(pmax.y, AVAIL_CENTER.y + AVAIL_H * 0.5 + PX_EPS, "size=%d 顶点不得越出可用区下界" % n)
		# 若回退成「按 size×size 包围盒分配空间」，unit 会退化到下面这个值 ⇒ 六边形明显偏小（本任务要修的观感）
		var naive: float = minf(AVAIL_W / float(n), AVAIL_H / float(n))
		assert_gt(unit, naive, "size=%d 蜂窝实际跨度应比包围盒方阵算出的大" % n)
		print("[T4 size=%d] unit_px=%.3f  视觉包围盒=%.1f×%.1f px  六边形内切半径=%.2f px  内接正方形边长=%.2f px (cell_px=%d)  包围盒方阵对照 unit=%.3f" % [
			n, unit, w, h, BV.HEX_INRADIUS * unit, 2.0 * BV.HEX_SQ_HALF * unit,
			int(lay["cell_px"]), naive])


# ==================== ② 蜂窝几何（board_view 接线） ====================

func test_board_view_hex_geometry_wiring() -> void:
	assert_true(FileAccess.file_exists("res://levels/hex_01.json"), "需要 hex_01.json（先重生成关卡）")
	assert_true(GameSession.start_level("res://levels/hex_01.json"), "应能开 hex_01")
	var view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(view)
	await wait_process_frames(1)
	assert_true(view._hex_layout(), "hex_01 的棋盘应判为蜂窝几何")
	var unit: float = view._unit_px()
	assert_gt(unit, 0.0, "蜂窝 unit_px 应为正")
	var pos := Vector2i(2, 2)
	var c: Vector2 = view._cell_center(pos)
	assert_almost_eq(c.x, view.board_origin.x + 0.75 * 4.0 * unit, PX_EPS, "格心 x = origin.x + 0.75*(x+y)*unit")
	assert_eq(c, BV.hex_center_px(pos, unit, view.board_origin), "实例换算必须与 static 纯函数完全一致")
	assert_eq(view._cell_polygon(pos).size(), 6, "蜂窝格轮廓应为 6 顶点")
	var r: Rect2 = view._cell_rect(pos)
	assert_almost_eq(r.size.x, 2.0 * BV.HEX_SQ_HALF * unit, PX_EPS, "传给 _draw_cell 的矩形 = 内接正方形")
	assert_almost_eq(r.position.x + r.size.x * 0.5, c.x, PX_EPS, "内接正方形以格心为中心（文字/旗子居中口径不变）")
	# 命中测试：格心必中自身；缝里也能点到（宽容 1.15×内切半径）；盘外远处返回 (-1,-1)
	for q in [Vector2i(2, 2), Vector2i(4, 0), Vector2i(0, 4), Vector2i(1, 3)]:
		assert_eq(view._pick(view._cell_center(q)), q, "格心必命中自身 (%d,%d)" % [q.x, q.y])
	# (2,2) 与 (3,1) 的格心在屏幕上恰好相差 (0, √3/2×unit)：(2,2) 的六边形在 0.4114×unit 处结束、
	# (3,1) 的从 0.4546×unit 开始 ⇒ 0.44 处正落在缝里，应命中较近的 (3,1) 而不是点空。
	assert_eq(view._pick(c + Vector2(0.0, 0.44 * unit)), Vector2i(3, 1), "缝里的点应命中最近格心")
	assert_eq(view._pick(c + Vector2(3.0 * unit, 0.0)), Vector2i(-1, -1), "远离盘面应返回 (-1,-1)")
	# 绘画层换算：蜂窝走晶格仿射映射，且「屏幕→棋盘→屏幕」必须互补（否则笔记会漂）
	var bp := Vector2(2.5, 1.25)
	var back: Vector2 = view._screen_pt_to_board(view._board_pt_to_screen(bp))
	assert_almost_eq(back.x, bp.x, 1e-3, "蜂窝换算 x 应可逆")
	assert_almost_eq(back.y, bp.y, 1e-3, "蜂窝换算 y 应可逆")
	GameSession.start_level("res://levels/classic_01.json")   # 复位全局盘面，避免污染后续测试


func test_board_view_rect_path_is_pixel_identical() -> void:
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要经典矩形关卡")
	var view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(view)
	await wait_process_frames(1)
	assert_false(view._hex_layout(), "矩形关卡不得走蜂窝几何")
	var pos := Vector2i(3, 4)
	# 与改动前的原式逐像素相等（这是「矩形关卡渲染与交互必须保持不变」的核心断言）
	assert_eq(view._cell_rect(pos),
			Rect2(view.board_origin + Vector2(pos.x, pos.y) * view.cell_px, Vector2(view.cell_px, view.cell_px)),
			"矩形路径的格位矩形必须与原式逐像素一致")
	assert_eq(view._cell_center(pos),
			view.board_origin + Vector2(pos.x, pos.y) * view.cell_px + Vector2(view.cell_px, view.cell_px) * 0.5,
			"矩形路径格心 = 原格矩形中心")
	assert_eq(view._cell_polygon(pos).size(), 4, "矩形格轮廓为 4 顶点")
	assert_eq(view._unit_px(), float(view.cell_px), "矩形路径 1 晶格单位 = 1 格 = cell_px")
	# 命中测试仍是矩形反算（格内任意点都反算到该格；棋盘外返回 -1,-1）
	assert_eq(view._pick(view._cell_center(pos)), pos, "格心命中自身")
	assert_eq(view._pick(view._cell_rect(pos).position + Vector2(1.0, 1.0)), pos, "格内左上角附近应命中该格")
	assert_eq(view._pick(view.board_origin - Vector2(1.0, 1.0)), Vector2i(-1, -1), "棋盘左上角外应点空")
	# 绘画层换算：矩形路径与改动前的旧式线性映射逐像素一致
	var pt := Vector2(3.5, 2.5)
	assert_eq(view._board_pt_to_screen(pt), view.board_origin + pt * view.cell_px,
			"矩形路径的棋盘→屏幕换算不得变化")
	assert_eq(view._screen_pt_to_board(pt), (pt - view.board_origin) / float(maxi(view.cell_px, 1)),
			"矩形路径的屏幕→棋盘换算不得变化")
