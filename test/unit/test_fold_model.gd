# test_fold_model.gd —— 静态折叠（FoldModel + TopologyModel.attach_fold）的门禁（2026-10-09）
#
# 本文件守三件事：
#   A. 几何：镜像索引 / 轴语义 / 配对顺序（a = 底层，b = 覆层）逐条对拍；
#   B. 缺口不静默：挖洞导致的「悬空」与「折过头」必须**报出来**（overhang / floating），
#      既不加边、也不丢掉这个事实；非法声明则整块拒绝且**一格都不改**；
#   C. 拓扑 → 线索：贴在一起的两格必须互相计数（走 classic 的 compute_clue_topo，
#      也就是玩家真正看到的那条路径）。
extends GutTest


func _rect_topo(rows: int, cols: int) -> Dictionary:
	var built := WrapTopology.build(rows, cols, ShapeGenerator.MOORE8, false, false, true)
	assert_true(bool(built["ok"]), "基座方阵应能建出来：%s" % str(built.get("reason", "")))
	return built["topology"] as Dictionary


func _positions(rows: int, cols: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in rows:
		for x in cols:
			out.append(Vector2i(x, y))
	return out


func _grid_of(topo: Dictionary) -> AdjacencyGrid:
	var g := AdjacencyGrid.new()
	g.setup_from_topo(topo)
	return g


# ==================== A. 几何 ====================

func test_axis_index_and_line_are_perpendicular() -> void:
	# x 轴 = 左右折：索引取 x、线取 y；y 轴反之。
	assert_eq(FoldModel.index_of(Vector2i(3, 7), FoldModel.AXIS_X), 3, "x 轴索引应是 x")
	assert_eq(FoldModel.line_of(Vector2i(3, 7), FoldModel.AXIS_X), 7, "x 轴的线应是 y")
	assert_eq(FoldModel.index_of(Vector2i(3, 7), FoldModel.AXIS_Y), 7, "y 轴索引应是 y")
	assert_eq(FoldModel.line_of(Vector2i(3, 7), FoldModel.AXIS_Y), 3, "y 轴的线应是 x")


func test_mirror_index_pairs_across_the_crease() -> void:
	# 折痕在 2 与 3 之间（at=3）：3↔2、4↔1、5↔0、6 翻过头（-1）。
	assert_eq(FoldModel.mirror_index(3, 3), 2, "折痕两侧相邻两格对折后应重合")
	assert_eq(FoldModel.mirror_index(3, 4), 1, "再远一格应落到次近的位置")
	assert_eq(FoldModel.mirror_index(3, 5), 0, "最远一格应落到近侧边界")
	assert_eq(FoldModel.mirror_index(3, 6), -1, "越过近侧边界的应得到负索引（折角翘出去）")
	# 自反：镜像两次回到原处（对合性）——配对逻辑成立的前提。
	for i in range(0, 12):
		assert_eq(FoldModel.mirror_index(3, FoldModel.mirror_index(3, i)), i,
			"镜像必须是对合（i=%d）" % i)


func test_normalize_rejects_bad_declarations() -> void:
	var ps := _positions(4, 6)
	var bad_axis := FoldModel.normalize({"axis": "z", "at": 3}, ps)
	assert_false(bool(bad_axis["ok"]), "非法轴名必须拒绝")
	assert_true("；".join(bad_axis["errors"]).contains("fold.axis"), "拒绝原因应点名 fold.axis")
	var bad_at := FoldModel.normalize({"axis": "x", "at": 0}, ps)
	assert_false(bool(bad_at["ok"]), "at = 0 必须拒绝（折痕不能在盘外）")
	var too_far := FoldModel.normalize({"axis": "x", "at": 6}, ps)
	assert_false(bool(too_far["ok"]), "at 越界（该轴只有 6 格）必须拒绝")
	var good := FoldModel.normalize({"axis": "x", "at": 3}, ps)
	assert_true(bool(good["ok"]), "6 格宽、at=3 应通过：%s" % str(good["errors"]))
	assert_eq(int(good["extent"]), 6, "extent 应报该轴总格数（UI 用它约束 at 上限）")
	assert_eq(good["fold"], {"axis": "x", "at": 3}, "规范化后只留 axis/at 两个字段")


func test_pairs_are_mirrored_and_ordered_base_to_cover() -> void:
	var ps := _positions(4, 6)
	var rep := FoldModel.audit({"axis": "x", "at": 3}, ps)
	assert_true(bool(rep["ok"]), "合法声明应通过：%s" % str(rep["errors"]))
	var pairs: Array = rep["pairs"]
	assert_eq(pairs.size(), 12, "6×4 折一半 ⇒ 3 列 × 4 行 = 12 对")
	assert_eq((rep["overhang"] as Array).size(), 0, "整半折无折角外露")
	assert_eq((rep["floating"] as Array).size(), 0, "整半折无悬空格")
	for pr: Dictionary in pairs:
		var a: Vector2i = pr["a"]
		var b: Vector2i = pr["b"]
		assert_true(a.x < 3, "a 必须在近侧（底层）：%s" % str(a))
		assert_true(b.x >= 3, "b 必须在远侧（覆层）：%s" % str(b))
		assert_eq(b.y, a.y, "配对不跨行：%s ↔ %s" % [str(a), str(b)])
		assert_eq(a.x + b.x, 2 * 3 - 1, "两格必须关于折痕镜像：%s ↔ %s" % [str(a), str(b)])
		assert_eq(FoldModel.mirror_index(3, b.x), a.x, "b 的镜像应正是 a")
	# 每一格最多只出现在一对里（一对一映射，不是多重配对）
	var seen := {}
	for pr2: Dictionary in pairs:
		var pa: Vector2i = pr2["a"]
		var pb: Vector2i = pr2["b"]
		for p in [pa, pb]:
			assert_false(seen.has(p), "%s 不应出现在两对里" % str(p))
			seen[p] = true
	assert_eq(seen.size(), 24, "近侧 12 + 远侧 12 全部参与配对")


func test_pair_map_is_bidirectional() -> void:
	var ps := _positions(3, 4)
	var pairs := FoldModel.pairs_of({"axis": "x", "at": 2}, ps)
	assert_eq(pairs.size(), 6, "4×3 折一半 ⇒ 2 列 × 3 行 = 6 对")
	var m := FoldModel.pair_map(pairs)
	assert_eq(m.size(), 12, "每一对登记两条（双向）")
	for pr: Dictionary in pairs:
		var a: Vector2i = pr["a"]
		var b: Vector2i = pr["b"]
		assert_eq(m.get(FoldModel.key_of(a), null), b, "a 应查到 b")
		assert_eq(m.get(FoldModel.key_of(b), null), a, "b 应查到 a")
	# 近侧那半在 4×3、at=2 下全部有对家；没有对家的格返回 null（不是 (0,0)）
	var lone: Variant = FoldModel.partner_of(pairs, Vector2i(9, 9))
	assert_null(lone, "不在配对里的格应返回 null，不许默认成 (0,0)")


func test_axis_y_folds_vertically() -> void:
	var ps := _positions(4, 3)
	var rep := FoldModel.audit({"axis": "y", "at": 2}, ps)
	assert_true(bool(rep["ok"]), "上下折应通过：%s" % str(rep["errors"]))
	assert_eq((rep["pairs"] as Array).size(), 6, "4 行折一半 ⇒ 2 行 × 3 列 = 6 对")
	for pr: Dictionary in rep["pairs"]:
		var a: Vector2i = pr["a"]
		var b: Vector2i = pr["b"]
		assert_eq(a.x, b.x, "上下折不跨列：%s ↔ %s" % [str(a), str(b)])
		assert_eq(a.y + b.y, 3, "两行应关于折痕镜像：%s ↔ %s" % [str(a), str(b)])


func test_holes_and_overhang_are_reported_not_dropped() -> void:
	# ① 挖洞：把远侧 (5,1) 挖掉 ⇒ 它的镜像 (0,1) 悬空；(5,1) 自己也不在盘上了。
	var ps: Array[Vector2i] = []
	for p in _positions(3, 6):
		if p != Vector2i(5, 1):
			ps.append(p)
	var rep := FoldModel.audit({"axis": "x", "at": 3}, ps)
	assert_true(bool(rep["ok"]), "挖洞盘仍是合法声明：%s" % str(rep["errors"]))
	assert_eq((rep["pairs"] as Array).size(), 8, "3×6 共 9 对，挖掉一格 ⇒ 8 对")
	var broken: Array = rep["floating"]
	assert_eq(broken.size(), 1, "挖洞后应报 1 个悬空格（它的对家被挖掉了）")
	assert_eq(broken[0], Vector2i(0, 1), "悬空的应是留在盘上的那一侧 (0,1)")
	# ② 折过头：7 列、at=3 ⇒ 远侧第 6 列镜像到 -1，翘出盘外。
	var ps2 := _positions(2, 7)
	var rep2 := FoldModel.audit({"axis": "x", "at": 3}, ps2)
	assert_true(bool(rep2["ok"]), "折角外露不是错误（只是提示）：%s" % str(rep2["errors"]))
	assert_eq((rep2["pairs"] as Array).size(), 6, "3 列近侧 × 2 行 = 6 对")
	var out: Array = rep2["overhang"]
	assert_eq(out.size(), 2, "多出来的那一列 2 格应全部记为折角外露")
	assert_eq(out[0], Vector2i(6, 0), "外露格应逐格列出（第一格）")


# ==================== B. 写进邻接表 ====================

func test_attach_fold_adds_exactly_one_edge_per_pair() -> void:
	var base := _rect_topo(3, 6)
	var before := _grid_of(base)
	var res := TopologyModel.attach_fold(base, {"axis": "x", "at": 3})
	assert_true(bool(res["ok"]), "合法折叠应成功：%s" % str(res["errors"]))
	var topo: Dictionary = res["topology"]
	var g := _grid_of(topo)
	assert_eq(g.cell_count(), 18, "折叠不改格数")
	assert_eq((res["pairs"] as Array).size(), 9, "应报出 9 对叠格")
	# 每一对的边双向存在，且**每格只多一个邻居**。
	# 例外：紧贴折痕的那一对（a.x == at-1 与 b.x == at）本来就在 8 邻域里，折过来
	# 只是「又叠了一层」——边已存在，度数不该再涨，所以只验配对不验 +1。
	for pr: Dictionary in (res["pairs"] as Array):
		var a: Vector2i = pr["a"]
		var b: Vector2i = pr["b"]
		assert_true(g.get_neighbors(a).has(b), "%s 应与 %s 相邻（贴在一起）" % [str(a), str(b)])
		assert_true(g.get_neighbors(b).has(a), "%s 应与 %s 相邻（贴在一起）" % [str(b), str(a)])
		if a.x == 2 and b.x == 3:
			continue
		assert_eq(g.get_neighbors(a).size(), before.get_neighbors(a).size() + 1,
			"%s 的度应恰好 +1" % str(a))
		assert_eq(g.get_neighbors(b).size(), before.get_neighbors(b).size() + 1,
			"%s 的度应恰好 +1" % str(b))
	# 规范化后仍是合法拓扑（加载器的硬闸门判据）
	var audit := TopologyModel.validate(topo)
	assert_true(bool(audit["ok"]), "折过的拓扑必须过体检：%s" % str(audit["errors"]))
	# 落盘的邻居序仍是规范序（按 (y,x) 升序）——新写的边不许破坏这条约定
	var nb: Array = topo["neighbors"][TopologyModel.key_of(Vector2i(5, 0))]
	var last := Vector2i(-1, -1)
	for raw in nb:
		var p := TopologyModel.parse_key(raw) as Vector2i
		assert_true(p.y > last.y or (p.y == last.y and p.x > last.x),
			"%s 的邻居序应保持 (y,x) 升序：%s" % [str(Vector2i(5, 0)), str(nb)])
		last = p


func test_attach_fold_rejects_invalid_without_touching_edges() -> void:
	var base := _rect_topo(3, 4)
	var res := TopologyModel.attach_fold(base, {"axis": "x", "at": 99})
	assert_false(bool(res["ok"]), "越界折痕必须拒绝")
	assert_eq((res["pairs"] as Array).size(), 0, "被拒时不得报出任何配对")
	var topo: Dictionary = res["topology"]
	assert_false(topo.has("fold"), "被拒时不得写 fold 元数据（否则半张折过的盘会被存下来）")
	var g := _grid_of(topo)
	var base_g := _grid_of(base)
	for p in g.all_positions():
		assert_eq(g.get_neighbors(p), base_g.get_neighbors(p), "%s 的邻居不许被改动" % str(p))


func test_fold_meta_survives_canonicalize_and_grid_setup() -> void:
	var base := _rect_topo(2, 4)
	var res := TopologyModel.attach_fold(base, {"axis": "x", "at": 2})
	var topo: Dictionary = res["topology"]
	assert_eq(topo["fold"], {"axis": "x", "at": 2}, "fold 元数据应写进拓扑（只留 axis/at）")
	# 加载器路径：canonicalize（去重/排序/丢盘外）之后元数据与边都必须还在
	var norm := TopologyModel.canonicalize(topo)
	var g := _grid_of(norm)
	assert_eq(str(g.view_meta.get("kind", "")), TopologyModel.VIEW_FOLD, "呈现类型应是折叠")
	assert_eq(g.view_meta.get("fold", {}), {"axis": "x", "at": 2}, "view_meta 应带上折痕")
	for pr: Dictionary in (res["pairs"] as Array):
		var a: Vector2i = pr["a"]
		var b: Vector2i = pr["b"]
		assert_true(g.get_neighbors(a).has(b), "归一化后叠格边仍在：%s -> %s" % [str(a), str(b)])
	# JSON 安全副本：写盘路径必须过这里（Vector2i 会被 stringify 成 "(0, 0)" 那种字符串）
	var safe := TopologyModel.json_safe_view(g.view_meta)
	assert_eq(safe.get("fold", {}), {"axis": "x", "at": 2}, "写盘的 view 里 fold 应原样保留")


# ==================== C. 线索语义（玩家真正看到的那条路径） ====================

func test_clue_counts_the_folded_partner() -> void:
	# 4×4、at=2：格 (2,1) 盖上 (1,1)。把雷放在覆层 (2,1) 上 ⇒ 底层 (1,1) 的线索
	# 必须把它算进去（这就是「两层贴在一起」的玩法含义）。
	var base := _rect_topo(4, 4)
	var res := TopologyModel.attach_fold(base, {"axis": "x", "at": 2})
	var g := _grid_of(res["topology"] as Dictionary)
	var ms := {}
	ms[Vector2i(2, 1)] = true
	var rule = RuleRegistry.default().resolve(&"classic")
	assert_not_null(rule, "classic 规则应已装配（见 test/_pre_run.gd）")
	var v := int(rule.call("compute_clue_topo", ms, Vector2i(1, 1), g, g.size()))
	assert_eq(v, 1, "底层格必须数到压在它上面的那一格里的雷")
	# 反向也成立（邻接是无向的）
	var v2 := int(rule.call("compute_clue_topo", ms, Vector2i(2, 1), g, g.size()))
	assert_eq(v2, 0, "覆层格自己不是雷的邻居（除非另有相邻雷）")
