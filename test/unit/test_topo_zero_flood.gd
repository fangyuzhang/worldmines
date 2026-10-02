# test_topo_zero_flood.gd —— 拓扑盘「0 值扩散」契约（2026-10-02 补齐的"值接了、扩散没接"）
#
# 背景：异形盘上的线索值早就走了规则自己的 `compute_clue_topo`，但**0 值扩散**一直是
# `board.gd` 里硬编码的"0 ⇒ 全部拓扑邻格"。这对计数型规则（classic）正确，对加权/压缩型
# 规格则等于"免费翻开不在线索保证范围内的格"。本文件钉住三件事：
#   1) classic（不覆写）在环绕盘上的扩散行为**与修复前逐位一致**（不能有回归）；
#   2) 基类默认契约 `zero_safe_neighbors_topo` 的语义（0 值 ⇒ 拓扑邻格；非整数 ⇒ 不扩散）；
#   3) 规格插件的覆写是**保守**的：纯邻域和且覆盖度足够才泛洪，其余一律不扩散。
extends GutTest


func _doc(rows: int, cols: int, mines: Array) -> EditorDoc:
	var d := EditorDoc.new(rows, cols)
	for m in mines:
		d.mines.append(m)
	return d


func _topo_spec(id: String, ref_count: int) -> Dictionary:
	var xs: Array = []
	for i in ref_count:
		xs.append({"t": "ref", "i": i})
	return {
		"spec_version": 1, "id": id, "title": "拓扑扩散测试", "geometry": "adj_generic",
		"clue": {"refs": "topo", "expr": {"t": "sum", "xs": xs}},
	}


func _spec_rule(spec: Dictionary) -> Object:
	var r := SpecRulePlugin.from_json(JSON.stringify(spec))
	assert_true(bool(r["ok"]), "测试用规格应合法：%s" % str(r["errors"]))
	return r.get("rule", null)


# ==================== 1. classic 行为不回归（走 Board 真路径） ====================

func test_classic_floods_topological_neighbors_on_wrap_board() -> void:
	# 角落里放一颗雷，选一个离它足够远的格（环绕 7x7 上取 (0,0) 与 (3,3) 不相邻）
	var doc := _doc(7, 7, [Vector2i(0, 0), Vector2i(6, 6)])
	doc.wrap = true
	var board := doc.build_board()
	assert_not_null(board, "环绕盘应能建出 Board")
	var p := Vector2i(3, 3)
	var cell: Cell = board.grid.get_cell(p)
	assert_eq(int(cell.value), 0, "该格离两颗雷都不相邻，值应为 0（构造前提）")
	var flood: Array[Vector2i] = board._flood_neighbors(p)
	assert_eq(flood.size(), 8, "classic 在环绕盘上仍应把 8 个拓扑邻格视为安全格（无回归）")
	for nb in board.grid.get_neighbors(p):
		assert_true(flood.has(nb), "拓扑邻格都应在扩散集合里：%s" % str(nb))


func test_nonzero_clue_never_floods() -> void:
	var doc := _doc(7, 7, [Vector2i(3, 4)])
	var board := doc.build_board()
	assert_not_null(board, "应能建出 Board")
	var p := Vector2i(3, 3)
	assert_true(int(board.grid.get_cell(p).value) > 0, "该格与雷相邻，值应 > 0（构造前提）")
	assert_eq(board._flood_neighbors(p).size(), 0, "非 0 值格永不扩散")


# ==================== 2. 基类默认契约 ====================

func test_base_contract_defaults_to_topological_neighbors() -> void:
	var doc := _doc(5, 5, [Vector2i(0, 0), Vector2i(4, 4)])
	doc.wrap = true
	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(doc.topology())
	var base := RulePlugin.new()
	var out := base.zero_safe_neighbors_topo(Vector2i(2, 2), ag, 0)
	assert_eq(out.size(), 8, "基类默认：0 值 ⇒ 拓扑邻格（＝修复前的硬编码行为）")
	assert_eq(base.zero_safe_neighbors_topo(Vector2i(2, 2), ag, 3).size(), 0, "非 0 值不扩散")
	assert_eq(base.zero_safe_neighbors_topo(Vector2i(2, 2), ag, [1, 2]).size(), 0,
		"非整数线索值（双值型）不参与自动扩散")
	assert_eq(base.zero_safe_neighbors_topo(Vector2i(2, 2), null, 0).size(), 0, "topo 为空时不得崩")


# ==================== 3. 规格插件的覆写必须保守 ====================

func test_spec_override_floods_only_for_pure_count_sum_with_full_coverage() -> void:
	var doc := _doc(5, 5, [Vector2i(0, 0), Vector2i(4, 4)])
	doc.wrap = true
	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(doc.topology())
	var degree := ag.get_neighbors(Vector2i(2, 2)).size()
	assert_eq(degree, 8, "环绕 5x5 上每格 8 度（构造前提）")

	# (a) 纯邻域和 + 覆盖度足够（引用 8 个邻居）⇒ 等价计数语义 ⇒ 允许泛洪
	var ok_rule := _spec_rule(_topo_spec("spec_flood_full_%d" % randi(), degree))
	assert_eq(ok_rule.zero_safe_neighbors_topo(Vector2i(2, 2), ag, 0).size(), degree,
		"纯邻域和且覆盖全部邻居 ⇒ 与计数语义等价，允许泛洪")

	# (b) 只引用前 2 个邻居（覆盖度不足）⇒ 未被引用的邻居不在保证范围内 ⇒ 不扩散
	var partial := _spec_rule(_topo_spec("spec_flood_partial_%d" % randi(), 2))
	assert_eq(partial.zero_safe_neighbors_topo(Vector2i(2, 2), ag, 0).size(), 0,
		"只覆盖部分邻居时不得泛洪（否则会翻开不在线索范围内的格）")

	# (c) 加权和：形状不是纯 ref 序列 ⇒ 一律不扩散
	var weighted := {
		"spec_version": 1, "id": "spec_flood_weighted_%d" % randi(), "title": "加权", "geometry": "adj_generic",
		"clue": {"refs": "topo", "expr": {"t": "wsum", "ws": [2, 2], "xs": [{"t": "ref", "i": 0}, {"t": "ref", "i": 1}]}},
	}
	var w_rule := _spec_rule(weighted)
	assert_eq(w_rule.zero_safe_neighbors_topo(Vector2i(2, 2), ag, 0).size(), 0,
		"加权规格不做数值推断 ⇒ 保守不扩散")

	# (d) 非 0 值：任何规格都不扩散
	assert_eq(ok_rule.zero_safe_neighbors_topo(Vector2i(2, 2), ag, 5).size(), 0, "非 0 值不扩散")
