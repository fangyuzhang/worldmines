extends GutTest
## test_shape_generator.gd —— ShapeGenerator 形状生成的数学门禁（纯函数，无引擎/UI 依赖）。
## 覆盖：三族参数化生成器（holed_grid / hex / t488）+ (d) mask 驱动生成（T7，文件末一节）。
##
## 断言口径：只用精确数学量（格数 / 无向边数 / 逐格度 / 度分布多重集 / bbox），
## 不用「看起来像」的弱断言。所有数字由 core/shape_generator.gd 头注释里的规则独立手算，
## 每条断言旁注明推导式，便于复核。
##
## (d) mask 一节的交叉验证口径：mask 版与参数化生成器「同族同形」时，positions/adjacency
## 必须**逐字节相等**（两条独立路径互证：一条从轮廓字符集建图、一条从参数公式建图）；
## 只比「格数/边数」强度不够——规模相同而接线不同的图会漏网。
##
## 度分布多重集 {度: 该度的格数} 与坐标原点无关（可跨平移比较），但它只是同构的**必要**条件，
## 本文件不拿它当同构证据——见 test_hex3_vs_hex_board_audit 的实测结论。

## 既有测试常量（7 格蜂窝样例，以盘心为原点 ⇒ 含负坐标）。
## 直接引用避免抄一份会漂移的副本。
const ModTopo := preload("res://test/unit/test_mod_topology.gd")


# ==================== 工具 ====================

func _key(p: Vector2i) -> String:
	return "%d,%d" % [p.x, p.y]


## topo → {坐标键: true}
func _pos_keys(topo: Dictionary) -> Dictionary:
	var out := {}
	for p in topo["positions"]:
		out[_key(Vector2i(int(p["x"]), int(p["y"])))] = true
	return out


## topo → {规范无向边键: true}。规范 = 端点按 (x,y) 字典序排定（与生成器同口径，此处独立重算）。
func _edge_keys(topo: Dictionary) -> Dictionary:
	var out := {}
	for e in topo["adjacency"]:
		var a := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		var b := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
		var lo := a
		var hi := b
		if b.x < a.x or (b.x == a.x and b.y < a.y):
			lo = b
			hi = a
		out["%s|%s" % [_key(lo), _key(hi)]] = true
	return out


## topo → {坐标键: 度}
func _degrees(topo: Dictionary) -> Dictionary:
	var out := {}
	for k in _pos_keys(topo):
		out[k] = 0
	for e in topo["adjacency"]:
		var a := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		var b := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
		out[_key(a)] = int(out[_key(a)]) + 1
		out[_key(b)] = int(out[_key(b)]) + 1
	return out


func _deg(topo: Dictionary, p: Vector2i) -> int:
	return int(_degrees(topo)[_key(p)])


## topo → 度分布多重集 {度: 该度的格数}
func _deg_multiset(topo: Dictionary) -> Dictionary:
	var out := {}
	var degs := _degrees(topo)
	for k in degs:
		var d: int = int(degs[k])
		out[d] = int(out.get(d, 0)) + 1
	return out


## 经 GridInterface 消费后重算的无向边数（度数总和 / 2）——用于验证「不丢边/不造边」。
func _grid_edge_count(g: GridInterface) -> int:
	var total := 0
	for p in g.all_positions():
		total += g.get_neighbors(p).size()
	return total / 2


## 三族共同不变量：坐标非负整数 / 无自环 / 无重复 / 邻接端点闭合。
func _assert_invariants(topo: Dictionary, label: String) -> void:
	var positions: Array = topo["positions"]
	var adjacency: Array = topo["adjacency"]
	assert_gt(positions.size(), 0, "%s: 应产出格" % label)
	var pos_keys := _pos_keys(topo)
	assert_eq(pos_keys.size(), positions.size(), "%s: positions 不得有重复坐标" % label)
	for p in positions:
		assert_eq(typeof(p["x"]), TYPE_INT, "%s: 坐标 x 必须是 int" % label)
		assert_eq(typeof(p["y"]), TYPE_INT, "%s: 坐标 y 必须是 int" % label)
		assert_true(int(p["x"]) >= 0 and int(p["y"]) >= 0,
				"%s: 坐标必须非负（board.gd 直接 setup_from_topo，不做 normalized）" % label)
	for e in adjacency:
		var a := Vector2i(int(e["a"]["x"]), int(e["a"]["y"]))
		var b := Vector2i(int(e["b"]["x"]), int(e["b"]["y"]))
		assert_ne(a, b, "%s: 不允许自环 %s" % [label, _key(a)])
		assert_true(pos_keys.has(_key(a)) and pos_keys.has(_key(b)),
				"%s: 邻接端点必须在 positions 内（%s - %s）" % [label, _key(a), _key(b)])
	assert_eq(_edge_keys(topo).size(), adjacency.size(), "%s: 同一无向边不得重复出现" % label)


## 契约：能被 AdjacencyGrid 无损消费（cell_count 对齐、边数不变）+ 邻接对称。
func _assert_consumable(topo: Dictionary, label: String) -> void:
	var positions: Array = topo["positions"]
	var adjacency: Array = topo["adjacency"]
	var g := AdjacencyGrid.new()
	g.setup_from_topo(topo)
	assert_eq(g.cell_count(), positions.size(), "%s: cell_count 应等于 positions.size()" % label)
	assert_eq(g.all_positions().size(), positions.size(), "%s: all_positions 应等于 positions.size()" % label)
	assert_eq(_grid_edge_count(g), adjacency.size(),
			"%s: setup_from_topo 不得丢边或造边（度数总和/2 应等于 adjacency.size）" % label)
	for p in g.all_positions():
		for nb in g.get_neighbors(p):
			assert_true(g.get_neighbors(nb).has(p), "%s: 邻接不对称 %s→%s" % [label, _key(p), _key(nb)])


# ==================== (a) 挖洞方格 ====================

func test_holed_grid_3x3_baseline() -> void:
	var t := ShapeGenerator.build_holed_grid(3, 3)
	_assert_invariants(t, "holed(3,3)")
	_assert_consumable(t, "holed(3,3)")
	assert_eq(t["positions"].size(), 9, "3×3 满格应 9 格")
	# 水平 3 行×2 + 垂直 3 列×2 + 对角 2×(rows-1)×(cols-1)=8 → 20
	assert_eq(t["adjacency"].size(), 20, "Moore 8 邻无向边 = 6 + 6 + 8 = 20")
	assert_eq(_deg(t, Vector2i(0, 0)), 3, "角格 (0,0)：2 正交 + 1 对角 = 3")
	assert_eq(_deg(t, Vector2i(1, 0)), 5, "边格 (1,0)：3 正交 + 2 对角 = 5")
	assert_eq(_deg(t, Vector2i(1, 1)), 8, "中心 (1,1)：全部 8 邻 = 8")
	assert_eq(_deg_multiset(t), {3: 4, 5: 4, 8: 1}, "度分布：4 角 + 4 边中 + 1 心（校验边数 40/2=20）")
	var g := AdjacencyGrid.new()
	g.setup_from_topo(t)
	assert_eq(g.size(), Vector2i(3, 3), "bbox 3×3")


func test_holed_grid_3x3_center_hole() -> void:
	var t := ShapeGenerator.build_holed_grid(3, 3, [Vector2i(1, 1)])
	_assert_invariants(t, "holed(3,3,[中心])")
	_assert_consumable(t, "holed(3,3,[中心])")
	assert_eq(t["positions"].size(), 8, "挖 1 格 → 8 格")
	assert_eq(t["adjacency"].size(), 12, "20 − 中心格 8 条关联边 = 12")
	# 删格不重连 ⇒ 四角各丢掉唯一那条「到中心的对角边」：3 − 1 = 2
	# 度分布推导：4 角×2 + 4 边中×(5−1=4) = 8 + 16 = 24 → 边数 24/2 = 12（与上式互证）
	for corner in [Vector2i(0, 0), Vector2i(2, 0), Vector2i(0, 2), Vector2i(2, 2)]:
		assert_eq(_deg(t, corner), 2, "角格 %s 与洞格对角相邻 ⇒ 度 3−1=2" % _key(corner))
	assert_eq(_deg_multiset(t), {2: 4, 4: 4}, "度分布：4 角×2 + 4 边中×4（8+16=24 → 12 边，与上式互证）")
	var g := AdjacencyGrid.new()
	g.setup_from_topo(t)
	assert_eq(g.size(), Vector2i(3, 3), "bbox 仍 3×3（洞不影响包围盒）")


func test_holed_grid_3x3_corner_hole() -> void:
	var t := ShapeGenerator.build_holed_grid(3, 3, [Vector2i(0, 0)])
	_assert_invariants(t, "holed(3,3,[角])")
	_assert_consumable(t, "holed(3,3,[角])")
	assert_eq(t["positions"].size(), 8, "挖 1 格 → 8 格")
	# 角格度 3 ⇒ 删它只删 3 条边：20 − 3 = 17
	assert_eq(t["adjacency"].size(), 17, "20 − 角格 3 条关联边 = 17")
	assert_eq(_deg(t, Vector2i(1, 1)), 7, "中心格与 (0,0) 对角相邻 ⇒ 度 8−1=7")
	assert_eq(_deg_multiset(t), {3: 3, 4: 2, 5: 2, 7: 1},
			"度分布：(1,0)/(0,1) 5→4、(1,1) 8→7、其余角 3、边中 5")


func test_holed_grid_holes_accept_vector2i_and_dict() -> void:
	# 同一形状的两种 holes 写法（Vector2i / JSON 口径 {x,y}）必须逐字节等价
	var a := ShapeGenerator.build_holed_grid(4, 4, [Vector2i(1, 1), Vector2i(2, 2)])
	var b := ShapeGenerator.build_holed_grid(4, 4, [{"x": 1, "y": 1}, {"x": 2, "y": 2}])
	assert_eq(a["positions"].size(), 14, "4×4 = 16 格 − 2 洞 = 14")
	assert_eq(a, b, "holes 的 Vector2i 与 {x,y} 两种写法应产出完全相同的拓扑")


func test_holed_grid_invalid_rows_returns_empty() -> void:
	assert_eq(ShapeGenerator.build_holed_grid(0, 3), {"positions": [], "adjacency": []},
			"rows<=0 → 空拓扑（连满格都建不出来）")
	assert_push_error("rows/cols 必须为正整数")


func test_holed_grid_invalid_cols_returns_empty() -> void:
	assert_eq(ShapeGenerator.build_holed_grid(3, -1), {"positions": [], "adjacency": []},
			"cols<=0 → 空拓扑")
	assert_push_error("rows/cols 必须为正整数")


func test_holed_grid_out_of_range_holes_skipped() -> void:
	# 越界洞：跳过该洞（盘面照常可用），但必须 push_error（不能静默产出不符数据的形状）
	var t := ShapeGenerator.build_holed_grid(3, 3, [Vector2i(5, 5), Vector2i(-1, 0)])
	assert_eq(t["positions"].size(), 9, "越界洞被跳过 ⇒ 仍 9 格")
	assert_eq(t["adjacency"].size(), 20, "越界洞被跳过 ⇒ 仍 20 边")
	assert_push_error_count(2, "两个越界洞各应报一次错")


func test_holed_grid_malformed_hole_skipped() -> void:
	var t := ShapeGenerator.build_holed_grid(3, 3, ["oops"])
	assert_eq(t["positions"].size(), 9, "无法解析的洞被跳过 ⇒ 仍 9 格")
	assert_push_error("洞坐标无法解析")


# ==================== (b) 蜂窝 ====================

func test_hex3_baseline() -> void:
	var t := ShapeGenerator.build_hex(3)
	_assert_invariants(t, "hex(3)")
	_assert_consumable(t, "hex(3)")
	# 裁剪 abs(r+c-2) <= 1 → r+c ∈ {1,2,3} → 7 格
	assert_eq(t["positions"].size(), 7, "size=3 六边形盘应 7 格")
	# 三类对称边各 4 条（每类 = 满足「两端都在盘内」的方向数）→ 12
	assert_eq(t["adjacency"].size(), 12, "7 格盘：3 类偏移各 4 条 = 12")
	assert_eq(_deg(t, Vector2i(1, 1)), 6, "盘心 (r+c=size-1) 应为 6 邻")
	assert_eq(_deg_multiset(t), {3: 6, 6: 1}, "度分布：6 环格×3 + 盘心×6（18+6=24 → 12 边）")
	var g := AdjacencyGrid.new()
	g.setup_from_topo(t)
	assert_eq(g.size(), Vector2i(3, 3), "bbox 3×3")
	for p in g.all_positions():
		assert_true(p.x >= 0 and p.y >= 0, "hex 坐标必须非负（原点固定在 (0,0)）")


func test_hex5_baseline() -> void:
	var t := ShapeGenerator.build_hex(5)
	_assert_invariants(t, "hex(5)")
	_assert_consumable(t, "hex(5)")
	# 裁剪 abs(r+c-4) <= 2 → r+c ∈ [2,6] → 3+4+5+4+3 = 19 格
	assert_eq(t["positions"].size(), 19, "size=5 六边形盘应 19 格")
	# 三类偏移各 14 条 → 42（度数总和 84/2 = 42，两法互证）
	assert_eq(t["adjacency"].size(), 42, "19 格盘：3 类偏移各 14 条 = 42")
	assert_eq(_deg_multiset(t), {3: 6, 4: 6, 6: 7},
			"度分布：6 角×3 + 6 边中×4 + 7 内格×6（18+24+42=84 → 42 边）")
	var g := AdjacencyGrid.new()
	g.setup_from_topo(t)
	assert_eq(g.size(), Vector2i(5, 5), "bbox 5×5")


func test_hex3_is_wheel_w6() -> void:
	# 度分布 + 边数只是必要条件；这里补上「环是**单个** 6 环」的证明：
	# 6 个环格环内度全为 2（⇒ 6 条环内边，2-正则）+ 环内无三角形 ⇒ 只能是 C6，非 C3+C3
	var t := ShapeGenerator.build_hex(3)
	var g := AdjacencyGrid.new()
	g.setup_from_topo(t)
	var center := Vector2i(1, 1)
	var ring: Array = g.get_neighbors(center)
	assert_eq(ring.size(), 6, "盘心应恰有 6 个邻格")
	for p in ring:
		assert_eq(_deg(t, p), 3, "环格 %s 度应为 3（盘心 1 + 环内 2）" % _key(p))
		var ring_nb: Array = []
		for nb in g.get_neighbors(p):
			if nb != center:
				ring_nb.append(nb)
		assert_eq(ring_nb.size(), 2, "环格 %s 应恰有 2 个环内邻格" % _key(p))
		assert_false(g.get_neighbors(ring_nb[0]).has(ring_nb[1]),
				"环内不应出现三角形 %s-%s（否则是 2 个三角形而非 6 环）" % [_key(ring_nb[0]), _key(ring_nb[1])])


func test_hex3_vs_hex_board_audit() -> void:
	# 契约兼容门禁：既有常量 HEX_BOARD（test_mod_topology.gd）应与 build_hex(3) 同构。
	# HEX_BOARD 以盘心为原点（含负坐标，用于覆盖 normalized 路径），整体平移 (+1,+1)
	# 后盘心 (0,0)→(1,1) 与 build_hex(3) 对齐 ⇒ 逐边比较可直接判同构。
	var hex3 := ShapeGenerator.build_hex(3)
	var board: Dictionary = ModTopo.HEX_BOARD
	var gb := AdjacencyGrid.new()
	gb.setup_from_topo(board)
	assert_eq(hex3["positions"].size(), board["positions"].size(), "格数一致：均 7")
	assert_eq(hex3["adjacency"].size(), board["adjacency"].size(), "边数一致：均 12")
	assert_eq(_deg_multiset(hex3), {3: 6, 6: 1}, "build_hex(3) = 轮图 W6：6 环格度 3 + 盘心度 6")
	assert_eq(_deg_multiset(board), {3: 6, 6: 1}, "HEX_BOARD 亦为 W6（度分布一致）")
	# 逐边同构：平移 (+1,+1) 后边集必须与 build_hex(3) 完全相等（含 6 条中心边 + 6 条 C6 环边）
	var shift := Vector2i(1, 1)
	var shifted := {}
	for e in board["adjacency"]:
		var a := Vector2i(int(e["a"]["x"]), int(e["a"]["y"])) + shift
		var b := Vector2i(int(e["b"]["x"]), int(e["b"]["y"])) + shift
		var lo := a
		var hi := b
		if b.x < a.x or (b.x == a.x and b.y < a.y):
			lo = b
			hi = a
		shifted["%s|%s" % [_key(lo), _key(hi)]] = true
	assert_eq(shifted, _edge_keys(hex3),
			"HEX_BOARD 平移 (+1,+1) 后应与 build_hex(3) 边集逐条相等 ⇒ 同构")
	assert_eq(gb.cell_count(), 7, "HEX_BOARD 仍应可被 AdjacencyGrid 正常消费")


# ==================== (c) T488（截角正方形镶嵌 4.8.8） ====================

func test_t488_2_baseline() -> void:
	var t := ShapeGenerator.build_t488(2)
	_assert_invariants(t, "t488(2)")
	_assert_consumable(t, "t488(2)")
	# 4 八边形 (0,0)(2,0)(0,2)(2,2) + 1 小方块 (1,1)
	assert_eq(t["positions"].size(), 5, "size=2：2² 八边形 + 1² 小方块 = 5 格")
	assert_eq(t["adjacency"].size(), 8, "八边形正交 2×size×(size-1)=4 + 小方块 4×1=4 → 8")
	assert_eq(_deg(t, Vector2i(1, 1)), 4, "小方块度 4（连 4 个八边形）")
	for c in 2:
		for r in 2:
			assert_eq(_deg(t, Vector2i(2 * c, 2 * r)), 3, "八边形 (%d,%d) 度 3（size=2 时全是角）" % [2 * c, 2 * r])
	assert_eq(_deg_multiset(t), {3: 4, 4: 1}, "度分布：4 八边形×3 + 1 小方块×4（12+4=16 → 8 边）")


func test_t488_3_baseline() -> void:
	var t := ShapeGenerator.build_t488(3)
	_assert_invariants(t, "t488(3)")
	_assert_consumable(t, "t488(3)")
	assert_eq(t["positions"].size(), 13, "size=3：3² 八边形 + 2² 小方块 = 13 格")
	assert_eq(t["adjacency"].size(), 28, "八边形正交 2×3×2=12 + 小方块 4×4=16 → 28")
	assert_eq(_deg(t, Vector2i(2, 2)), 8, "中心八边形 (2,2)：4 正交八边形 + 4 小方块 = 8")
	assert_eq(_deg(t, Vector2i(0, 0)), 3, "角八边形 (0,0)：2 正交八边形 + 1 小方块 = 3")
	for c in 2:
		for r in 2:
			assert_eq(_deg(t, Vector2i(2 * c + 1, 2 * r + 1)), 4, "小方块 (%d,%d) 度必须为 4" % [2 * c + 1, 2 * r + 1])
	assert_eq(_deg_multiset(t), {3: 4, 4: 4, 5: 4, 8: 1},
			"度分布：4 角八边形×3 + 4 边八边形×5 + 1 心八边形×8 + 4 小方块×4（56/2=28 边）")
	var g := AdjacencyGrid.new()
	g.setup_from_topo(t)
	assert_eq(g.size(), Vector2i(5, 5), "bbox 5×5（×2 整数化后坐标跨 0..4）")


# ==================== (d) mask 驱动生成（T7）====================
#
# 交叉验证：mask 版与参数化生成器同族同形时，positions/adjacency 逐字节相等（见文件头）。
# 等值断言用**数组直接 assert_eq**（GDScript 对 Array/Dictionary 做逐元素深比较），
# 失败时 GUT 会打印首个差异位置，便于定位。

func test_mask_holed_grid_matches_build_holed_grid() -> void:
	# build_holed_grid(3, 3, [中心]) 的 mask 表达 = 3×3 满格挖中心（'.' 即洞）
	var a := ShapeGenerator.build_from_mask("holed_grid", ["###", "#.#", "###"])
	var b := ShapeGenerator.build_holed_grid(3, 3, [Vector2i(1, 1)])
	_assert_invariants(a, "mask(holed_grid)")
	_assert_consumable(a, "mask(holed_grid)")
	assert_eq(a["style"], "holed_grid", "style 应原样写入产物")
	assert_eq(a["positions"], b["positions"], "mask 与 build_holed_grid(3,3,[(1,1)]) 的 positions 应逐字节相等")
	assert_eq(a["adjacency"], b["adjacency"], "mask 与 build_holed_grid(3,3,[(1,1)]) 的 adjacency 应逐字节相等")


func test_mask_hex_matches_build_hex() -> void:
	# build_hex(3) 的裁剪式 = abs(r+c-2) <= 1 → 逐行 [".##","###","##."]（c=x，r=y）
	var a := ShapeGenerator.build_from_mask("hex", [".##", "###", "##."])
	var b := ShapeGenerator.build_hex(3)
	_assert_invariants(a, "mask(hex)")
	_assert_consumable(a, "mask(hex)")
	assert_eq(a["style"], "hex", "style 应原样写入产物")
	assert_eq(a["positions"], b["positions"], "mask 与 build_hex(3) 的 positions 应逐字节相等")
	assert_eq(a["adjacency"], b["adjacency"], "mask 与 build_hex(3) 的 adjacency 应逐字节相等")


func test_mask_t488_matches_build_t488() -> void:
	# 2×2 八边形 mask → 自动补小方块 (1,1)（其 4 个相邻八边形全在）
	var a := ShapeGenerator.build_from_mask("t488", ["##", "##"])
	var b := ShapeGenerator.build_t488(2)
	_assert_invariants(a, "mask(t488)")
	_assert_consumable(a, "mask(t488)")
	assert_eq(a["style"], "t488", "style 应原样写入产物")
	assert_eq(a["positions"], b["positions"], "mask 与 build_t488(2) 的 positions 应逐字节相等（含自动补的 (1,1)）")
	assert_eq(a["adjacency"], b["adjacency"], "mask 与 build_t488(2) 的 adjacency 应逐字节相等")


func test_mask_t488_auto_square_needs_all_four_octagons() -> void:
	# 三缺一：L 形 3 八边形 ⇒ 小方块不该出现（其 4 个相邻八边形必须全在）
	var t := ShapeGenerator.build_from_mask("t488", ["##", "#."])
	_assert_invariants(t, "mask(t488,L)")
	assert_eq(t["positions"].size(), 3, "L 形 3 八边形，不补小方块")
	assert_eq(t["adjacency"].size(), 2, "只留 (0,0)-(2,0)、(0,0)-(0,2) 两条正交边")


func test_mask_style_and_params_passthrough() -> void:
	var t := ShapeGenerator.build_from_mask("holed_grid", ["#"], {"mask": ["#"]})
	assert_eq(t["style"], "holed_grid", "style 透传")
	assert_eq(t["params"], {"mask": ["#"]}, "params 原样透传（调用方可塞 mask 供落盘审计）")
	assert_eq((t["positions"] as Array).size(), 1, "单格 mask → 1 格")
	assert_eq((t["adjacency"] as Array).size(), 0, "单格没有边")


func test_to_adjacency_grid_mask_entry() -> void:
	var g := ShapeGenerator.to_adjacency_grid("mask", {"style": "holed_grid", "mask": ["###", "#.#", "###"]})
	assert_true(g is AdjacencyGrid, "mask → AdjacencyGrid")
	assert_eq(g.cell_count(), 8, "挖心 3×3 = 8 格")
	assert_eq(_grid_edge_count(g), 12, "8 格挖洞方阵 = 12 边（与 build 侧互证）")
	assert_eq(g.style, "holed_grid", "mask 分支应带上 style（渲染/落盘依赖）")
	assert_eq(g.style_params, {"mask": ["###", "#.#", "###"]}, "mask 应随 params 落盘（JSON 审计）")
	assert_false(g.in_board(Vector2i(1, 1)), "洞格不在盘内")


func test_build_from_mask_unknown_style_returns_empty() -> void:
	assert_eq(ShapeGenerator.build_from_mask("nope", ["#"]), {"positions": [], "adjacency": []},
			"未注册 style → 空拓扑（不是部分结果）")
	assert_push_error("未注册的 style")


func test_build_from_mask_empty_mask_returns_empty() -> void:
	assert_eq(ShapeGenerator.build_from_mask("holed_grid", []), {"positions": [], "adjacency": []},
			"空 mask → 空拓扑")
	assert_push_error("mask 为空")


func test_build_from_mask_ragged_rows_return_empty() -> void:
	assert_eq(ShapeGenerator.build_from_mask("holed_grid", ["##", "#"]), {"positions": [], "adjacency": []},
			"行长不一致 → 空拓扑")
	assert_push_error("行长不一致")


func test_build_from_mask_invalid_char_returns_empty() -> void:
	assert_eq(ShapeGenerator.build_from_mask("holed_grid", ["#?", "##"]), {"positions": [], "adjacency": []},
			"非法字符 → 空拓扑")
	assert_push_error("非法字符")


func test_build_from_mask_all_empty_returns_empty() -> void:
	# 空格 / 0 都算空字符；全空 = 没有可建的格
	assert_eq(ShapeGenerator.build_from_mask("holed_grid", [". ", "0."]), {"positions": [], "adjacency": []},
			"全空 mask → 空拓扑")
	assert_push_error("没有任何格")


# ==================== 统一契约 ====================

func test_all_families_consumable_by_adjacency_grid() -> void:
	var cases: Array = [
		["holed_grid", ShapeGenerator.build_holed_grid(3, 3, [Vector2i(1, 1)])],
		["hex", ShapeGenerator.build_hex(3)],
		["t488", ShapeGenerator.build_t488(3)],
		["mask", ShapeGenerator.build_from_mask("holed_grid", ["###", "#.#", "###"])],
	]
	for c in cases:
		_assert_consumable(c[1], str(c[0]))


func test_normalized_zero_copy_and_bbox() -> void:
	var g := ShapeGenerator.to_adjacency_grid("hex", {"size": 3})
	assert_true(AdjacencyGrid.normalized(g) == g, "坐标已非负 → normalized 应原样返回原实例（零拷贝）")
	assert_eq(g.size(), Vector2i(3, 3), "bbox 3×3")
	# 负坐标（HEX_BOARD 以盘心为原点）→ 归一到非负的**新**实例
	var neg := AdjacencyGrid.new()
	neg.setup_from_topo(ModTopo.HEX_BOARD)
	var norm := AdjacencyGrid.normalized(neg)
	assert_true(norm != neg, "含负坐标 → 应返回新实例（不得原地改）")
	assert_eq(norm.cell_count(), 7, "归一化不增删格")
	assert_eq(norm.size(), Vector2i(3, 3), "归一化后 bbox 3×3")
	assert_eq(_grid_edge_count(norm), 12, "归一化不增删边")
	for p in norm.all_positions():
		assert_true(p.x >= 0 and p.y >= 0, "归一化后坐标必须非负")


func test_to_adjacency_grid_entry() -> void:
	var h := ShapeGenerator.to_adjacency_grid("hex", {"size": 5})
	assert_true(h is AdjacencyGrid, "hex → AdjacencyGrid")
	assert_eq(h.cell_count(), 19, "hex(5) 19 格")
	assert_eq(_grid_edge_count(h), 42, "hex(5) 42 边")
	var g := ShapeGenerator.to_adjacency_grid("holed_grid", {"rows": 3, "cols": 3, "holes": [{"x": 1, "y": 1}]})
	assert_true(g is AdjacencyGrid, "holed_grid → AdjacencyGrid")
	assert_eq(g.cell_count(), 8, "挖洞方格 8 格")
	assert_eq(g.size(), Vector2i(3, 3), "bbox 3×3")
	var q := ShapeGenerator.to_adjacency_grid("t488", {"size": 2})
	assert_true(q is AdjacencyGrid, "t488 → AdjacencyGrid")
	assert_eq(q.cell_count(), 5, "t488(2) 5 格")


func test_to_adjacency_grid_unknown_kind_returns_null() -> void:
	assert_true(ShapeGenerator.to_adjacency_grid("nope", {}) == null, "未注册 kind → null（不是空盘）")
	assert_push_error("未注册的形状 kind")


func test_to_adjacency_grid_empty_shape_returns_null() -> void:
	assert_true(ShapeGenerator.to_adjacency_grid("hex", {"size": 0}) == null, "参数非法 → 空拓扑 → null")
	assert_push_error("size 必须为正整数")


func test_board_loads_generated_topology() -> void:
	var topo := ShapeGenerator.build_holed_grid(3, 3, [Vector2i(1, 1)])
	var level := {
		"size": {"rows": 3, "cols": 3},
		"total_mines": 1,
		"mines": [{"c": 0, "r": 0}],
		"revealed": [],
		"topology": topo,
	}
	var b := Board.new()
	b.load_level(level)
	assert_true(b.grid is AdjacencyGrid, "Board 应按 topology 重建异形棋盘")
	assert_eq(b.grid.cell_count(), (topo["positions"] as Array).size(), "cell_count 应与 positions 一致")
	assert_eq(b.grid.cell_count(), 8, "8 格异形盘")
	assert_eq(b.get_mine_positions().size(), 1, "1 个雷应落在盘内")
	assert_true(b.is_mine(Vector2i(0, 0)), "(0,0) 是雷")
	assert_false(b.grid.in_board(Vector2i(1, 1)), "洞格不在盘内（不是「不可通行」，而是不存在）")


# ==================== M6 + mask 边界 + 偶数尺寸（2026-09-21 审计补测） ====================

func test_mask_must_be_flush_top_left() -> void:
	# M6：mask 带左上留白 → 拒绝。理由：下游 normalized 会平移坐标，而落盘的 params.mask
	# 原样透传 ⇒ 两者失配（审计链断、bbox ≠ mask 行列数）。要求作者把图案贴到左上。
	var t := ShapeGenerator.build_from_mask("holed_grid", ["....", "..##", "..##"])
	assert_eq(t, {"positions": [], "adjacency": []}, "留白 mask 应返回空拓扑")
	assert_push_error("贴左上角")


func test_mask_single_cell() -> void:
	var t := ShapeGenerator.build_from_mask("holed_grid", ["#"])
	_assert_invariants(t, "mask 1×1")
	assert_eq(t["positions"].size(), 1, "1×1 mask → 1 格")
	assert_eq(t["adjacency"].size(), 0, "单格无邻接")


func test_mask_single_row_and_col() -> void:
	var r := ShapeGenerator.build_from_mask("holed_grid", ["###"])
	_assert_invariants(r, "mask 单行")
	assert_eq(r["positions"].size(), 3, "单行 3 格")
	assert_eq(r["adjacency"].size(), 2, "单行链 2 条边")
	var c := ShapeGenerator.build_from_mask("holed_grid", ["#", "#", "#"])
	_assert_invariants(c, "mask 单列")
	assert_eq(c["adjacency"].size(), 2, "单列链 2 条边")


func test_mask_disconnected_blocks_are_legal() -> void:
	# 非连通（两块互不相邻）是合法拓扑：不变量（对称/无自环/无重复/端点闭合）照常成立
	var t := ShapeGenerator.build_from_mask("holed_grid", ["#.#"])
	_assert_invariants(t, "mask 两块不相邻")
	assert_eq(t["positions"].size(), 2, "两块共 2 格")
	assert_eq(t["adjacency"].size(), 0, "中间隔空 → 无边")


func test_mask_t488_equals_parametric() -> void:
	# mask 的 t488 支线（自动补小方块）与参数化 build_t488 等价（size=2 已测，这里补 3×3）
	var via_mask := ShapeGenerator.build_from_mask("t488", ["###", "###", "###"])
	var via_gen := ShapeGenerator.build_t488(3)
	assert_eq(via_mask["positions"], via_gen["positions"], "t488 mask 的 positions 应与参数化一致")
	assert_eq(via_mask["adjacency"], via_gen["adjacency"], "t488 mask 的 adjacency 应与参数化一致")


func test_hex_even_sizes_closed_forms() -> void:
	# 偶数 size 蜂窝（4/6/8）：闭式与实现独立对照（此前只有产物文件覆盖——文件缺失即 pending）
	# 闭式（与 tools/gen_shape_levels.gd 的偶数分支同源、独立手算）：cells=3R²+5R+2、edges=9R²+9R+1
	var cases: Array = [[4, 10, 19], [6, 24, 55], [8, 44, 109]]   # [size, cells, edges]
	for c: Array in cases:
		var n := int(c[0])
		var t := ShapeGenerator.build_hex(n)
		_assert_invariants(t, "hex(%d)" % n)
		assert_eq(t["positions"].size(), int(c[1]), "hex(%d) 格数应等于偶数闭式" % n)
		assert_eq(_edge_keys(t).size(), int(c[2]), "hex(%d) 边数应等于偶数闭式" % n)
