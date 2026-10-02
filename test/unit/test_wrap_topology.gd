# test_wrap_topology.gd —— 环绕边界 / 自定义邻域 → 邻接表（编辑器 P1 几何内核）的自证
#
# 覆盖的不变量（这些是"编辑器能做环绕盘"的地基，坏一条就等于编辑器会产出不可玩的关）：
#   1) 默认 8 邻 + 不环绕 ⇒ **不产出 topology**（默认扫雷必须与今天逐位一致）；
#   2) 环绕 5x5 ⇒ 每格**恒 8 度**、全盘**对称**、坐标非负、无自环、无重复（用仓库自带审计器复核）；
#   3) 邻居顺序**按 (y,x) 升序**（与 spec 的 `refs:"topo"` 索引序一致 ⇒ 跨会话不漂移）；
#   4) 自定义偏移（正交 4）在非环绕下按棋盘边界截断，四角/边的度数正确；
#   5) 含自身 ⇒ 度数 +1 且自身在表内；
#   6) 上限与退化输入被拒（环绕组要 ≥2×2、格数上限、偏移数上限）；
#   7) `editor` 元数据可 JSON 往返还原，且**不污染 `params`**（渲染参数）。
extends GutTest


func _grid_of(topology: Dictionary) -> AdjacencyGrid:
	var g := AdjacencyGrid.new()
	g.setup_from_topo(topology)
	return g


# ==================== 1. 默认盘不产出 topology ====================

func test_default_moore8_yields_no_topology() -> void:
	var r := WrapTopology.build(5, 5)
	assert_true(bool(r["ok"]), "默认 8 邻应构建成功")
	assert_true((r["topology"] as Dictionary).is_empty(),
		"默认 8 邻 + 不环绕 + 不含自身 ⇒ 必须**不**产出 topology（让关卡继续走 RectGrid，产物与今天逐位一致）")
	assert_true(WrapTopology.is_default(ShapeGenerator.MOORE8, false, false),
		"is_default(MOORE8, 不含自身, 不环绕) 应为 true")


func test_default_detection_is_order_insensitive() -> void:
	var shuffled: Array[Vector2i] = []
	shuffled.assign(ShapeGenerator.MOORE8)
	shuffled.reverse()
	# 偏移的书写顺序不影响"是否为默认盘"的判定（集合语义）
	assert_true(WrapTopology.is_default(shuffled, false, false), "偏移顺序不应影响默认判定")
	assert_false(WrapTopology.is_default(ShapeGenerator.MOORE8, true, false), "含自身就不是默认盘")
	assert_false(WrapTopology.is_default(ShapeGenerator.MOORE8, false, true), "环绕就不是默认盘")
	assert_false(WrapTopology.is_default(WrapTopology.DIRS_ORTHO4, false, false), "正交 4 不是默认盘")


# ==================== 2. 环绕：度数 / 对称 / 审计 ====================

func test_wrap_5x5_every_cell_degree_8_and_symmetric() -> void:
	var r := WrapTopology.build(5, 5, ShapeGenerator.MOORE8, false, true)
	assert_true(bool(r["ok"]), "环绕盘应构建成功：%s" % str(r["reason"]))
	var topo: Dictionary = r["topology"]
	assert_false(topo.is_empty(), "环绕盘必须产出 topology（它不是默认矩形盘）")
	var g := _grid_of(topo)

	assert_eq(g.cell_count(), 25, "5x5 应有 25 格")
	for p in g.all_positions():
		var nbs: Array[Vector2i] = g.get_neighbors(p)
		assert_eq(nbs.size(), 8, "环绕 5x5 上每格的 8 邻必须**恰好 8 个**（折返后无重无缺）：%s" % str(p))
		for nb in nbs:
			assert_true(g.get_neighbors(nb).has(p),
				"邻接必须对称：%s 在 %s 的邻居里，反之亦然" % [str(nb), str(p)])

	# 折返的具体语义：左上角的"上/左"邻居来自对边
	var corner: Array[Vector2i] = g.get_neighbors(Vector2i(0, 0))
	for expect in [Vector2i(4, 4), Vector2i(0, 4), Vector2i(4, 0), Vector2i(1, 4), Vector2i(4, 1)]:
		assert_true(corner.has(expect), "(0,0) 的环绕邻居应包含 %s" % str(expect))


func test_wrap_topology_passes_repo_audit() -> void:
	# 用仓库**自己的**审计器复核（非负 / 无自环 / 无盘外 / 无重复 / 对称 / 连通性口径）
	var r := WrapTopology.build(7, 9, ShapeGenerator.MOORE8, false, true)
	assert_true(bool(r["ok"]), "环绕盘应构建成功")
	var g := _grid_of(r["topology"])
	var audit := AdjacencyBuilder.audit(g)
	assert_true(bool(audit["ok"]),
		"环绕盘必须通过仓库自带审计器，problems=%s" % str(audit["problems"]))
	assert_eq(int(audit["cell_count"]), 63, "7x9 = 63 格")
	# 每格 8 度 ⇒ 无向边数 = 63*8/2 = 252（环绕下无边界衰减）
	assert_eq(int(audit["edge_count"]), 252, "每格 8 度 ⇒ 无向边数 = 252")


func test_wrap_neighbors_are_sorted_by_y_then_x() -> void:
	# 顺序契约：与 `SpecRulePlugin._sorted_neighbors` 同序 ⇒ spec 的 ref i 跨会话稳定
	var g := _grid_of(WrapTopology.build(5, 5, ShapeGenerator.MOORE8, false, true)["topology"])
	var keys: Array = []
	for p in g.get_neighbors(Vector2i(0, 0)):
		keys.append("%d,%d" % [p.x, p.y])
	assert_eq(keys, ["1,0", "4,0", "0,1", "1,1", "4,1", "0,4", "1,4", "4,4"],
		"(0,0) 的邻居必须按 (y,x) 升序：先 y=0 组，再 y=1 组，再 y=4 组")


func test_topology_does_not_pollute_render_params() -> void:
	# `params` 会被 setup_from_topo 原样搬进 style_params 交给渲染层解释；
	# 编辑器元数据必须放在独立的 `editor` 键里，否则有污染渲染的风险。
	var topo: Dictionary = WrapTopology.build(5, 5, ShapeGenerator.MOORE8, false, true)["topology"]
	assert_false(topo.has("params"), "不得写 params（那是渲染参数，编辑器元数据应放 editor）")
	assert_eq(str(topo["style"]), "custom", "方格盘用 custom 渲染路径（不是 hex）")
	assert_true((topo["editor"] as Dictionary).has("dirs"), "editor 元数据里必须带 dirs 以便回读")


# ==================== 3. 自定义邻域（非环绕） ====================

func test_ortho4_without_wrap_truncates_at_border() -> void:
	var r := WrapTopology.build(3, 3, WrapTopology.DIRS_ORTHO4, false, false)
	assert_true(bool(r["ok"]), "正交 4 邻应构建成功")
	var g := _grid_of(r["topology"])
	assert_eq(g.get_neighbors(Vector2i(0, 0)).size(), 2, "非环绕时角落只有 2 个正交邻居")
	assert_eq(g.get_neighbors(Vector2i(1, 0)).size(), 3, "非环绕时边中格有 3 个正交邻居")
	assert_eq(g.get_neighbors(Vector2i(1, 1)).size(), 4, "非环绕时内部格有 4 个正交邻居")
	var audit := AdjacencyBuilder.audit(g)
	assert_true(bool(audit["ok"]), "自定义邻域盘也要过审计：%s" % str(audit["problems"]))


func test_include_self_adds_the_cell_itself() -> void:
	var r := WrapTopology.build(4, 4, WrapTopology.DIRS_ORTHO4, true, false)
	assert_true(bool(r["ok"]), "含自身的邻域应构建成功")
	var g := _grid_of(r["topology"])
	var p := Vector2i(1, 1)
	assert_eq(g.get_neighbors(p).size(), 5, "内部格：4 正交 + 自身 = 5")
	assert_true(g.get_neighbors(p).has(p), "含自身时该格必须出现在自己的邻接表里")


func test_knight_preset_is_available_for_the_editor() -> void:
	var r := WrapTopology.build(8, 8, WrapTopology.DIRS_KNIGHT8, true, false)
	assert_true(bool(r["ok"]), "骑士步邻域应构建成功（编辑器预设之一）")
	var g := _grid_of(r["topology"])
	assert_eq(g.get_neighbors(Vector2i(4, 4)).size(), 9, "内部格：8 骑士步 + 自身 = 9")


# ==================== 4. 上限与退化输入 ====================

func test_wrap_rejects_degenerate_boards() -> void:
	var r := WrapTopology.build(1, 8, ShapeGenerator.MOORE8, false, true)
	assert_false(bool(r["ok"]), "单行环绕必须被拒（±1 会折回自身，不是合法的环绕语义）")
	assert_true(str(r["reason"]).find("环绕") != -1, "理由必须点明环绕：%s" % str(r["reason"]))


func test_rejects_oversized_board_and_degree() -> void:
	var big := WrapTopology.build(100, 100, ShapeGenerator.MOORE8, false, true)
	assert_false(bool(big["ok"]), "100x100 超过 MAX_CELLS 必须被拒（加载器会拒收）")
	assert_true(str(big["reason"]).find("上限") != -1, "理由应含『上限』：%s" % str(big["reason"]))

	var many: Array[Vector2i] = []
	for i in WrapTopology.MAX_DEGREE + 1:
		many.append(Vector2i(i % 8, floori(i / 8.0)))   # A8：int/int 显式化
	var too_many := WrapTopology.build(5, 5, many, false, false)
	assert_false(bool(too_many["ok"]), "偏移数超过 MAX_DEGREE 必须被拒")


func test_force_emits_table_for_default_neighborhood() -> void:
	# force 的用途：**障碍格（洞）只能用邻接表表达**——"默认 8 邻 + 有障碍"的盘也必须产出表。
	var r := WrapTopology.build(4, 4, ShapeGenerator.MOORE8, false, false, true)
	assert_true(bool(r["ok"]), "force 构建应成功")
	assert_false((r["topology"] as Dictionary).is_empty(),
		"force=true 时即使邻域是默认的也必须产出邻接表")
	var g := _grid_of(r["topology"])
	assert_eq(g.get_neighbors(Vector2i(1, 1)).size(), 8, "非环绕下内部格仍是 8 邻")
	assert_eq(g.get_neighbors(Vector2i(0, 0)).size(), 3, "非环绕下角格按边界截断为 3 邻")
	var audit := AdjacencyBuilder.audit(g)
	assert_true(bool(audit["ok"]), "force 产出的表也要过审计：%s" % str(audit["problems"]))


# ==================== 5. 编辑器元数据往返 ====================

func test_editor_meta_round_trip() -> void:
	var dirs: Array[Vector2i] = []
	dirs.assign(WrapTopology.DIRS_KNIGHT8)
	var topo: Dictionary = WrapTopology.build(6, 6, dirs, true, true)["topology"]
	var meta := WrapTopology.read_editor_meta(topo)
	assert_true(bool(meta["wrap"]), "wrap 应往返还原")
	assert_true(bool(meta["include_self"]), "include_self 应往返还原")
	assert_eq((meta["dirs"] as Array).size(), 8, "dirs 应往返还原为 8 个偏移")
	assert_true((meta["dirs"] as Array).has(Vector2i(-1, -2)), "偏移内容应逐一还原")


func test_read_editor_meta_on_foreign_topology_falls_back_to_defaults() -> void:
	# 手工写的 / 旧版本的 topology 没有 editor 键 ⇒ 按默认解释，不能崩
	var foreign := {"positions": [{"x": 0, "y": 0}], "neighbors": {"0,0": []}}
	var meta := WrapTopology.read_editor_meta(foreign)
	assert_false(bool(meta["wrap"]), "缺 editor 键时 wrap 取默认 false")
	assert_eq((meta["dirs"] as Array).size(), 8, "缺 editor 键时 dirs 取默认 Moore 8")
