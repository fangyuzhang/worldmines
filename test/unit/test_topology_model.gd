extends GutTest

## 拓扑模型：安全门 + 虫洞/呈现元数据的核心契约。
## 这些断言保护的是“关卡自述的图”和“引擎实际使用的图”必须是同一张。

func _wrap_topo() -> Dictionary:
	var r := WrapTopology.build(5, 5, ShapeGenerator.MOORE8, false, true)
	assert_true(bool(r["ok"]), "环绕拓扑应能构建：%s" % str(r["reason"]))
	return r["topology"] as Dictionary


func _grid(topo: Dictionary) -> AdjacencyGrid:
	var g := AdjacencyGrid.new()
	g.setup_from_topo(topo)
	return g


func test_validate_wrap_passes() -> void:
	var audit := TopologyModel.validate(_wrap_topo())
	assert_true(bool(audit["ok"]), "合法环绕表应通过：%s" % str(audit["errors"]))
	assert_eq((audit["positions"] as Array).size(), 25, "5x5 应有 25 格")
	assert_eq(int(audit["asymmetric"]), 0, "环绕表必须对称")
	assert_eq(int(audit["self_loop"]), 0, "环绕表不得有自环")
	assert_eq(int(audit["dangling"]), 0, "环绕表不得有盘外邻接")


func test_validate_reports_dangling_duplicate_and_asymmetric_as_errors() -> void:
	var bad := {
		"positions": [{"x": 0, "y": 0}, {"x": 1, "y": 0}, {"x": 2, "y": 0}],
		"neighbors": {
			"0,0": ["1,0", "1,0", "9,9"],
			"1,0": [],
			"2,0": [],
		},
	}
	var audit := TopologyModel.validate(bad)
	assert_false(bool(audit["ok"]), "坏表必须判失败")
	assert_eq(int(audit["duplicate"]), 1, "应识别重复邻接")
	assert_eq(int(audit["dangling"]), 1, "应识别盘外邻接")
	assert_eq(int(audit["asymmetric"]), 1, "应识别单向邻接")
	var joined := "；".join(audit["errors"])
	assert_true(joined.contains("盘外"), "错误文案应说清楚盘外邻接")
	assert_true(joined.contains("不对称"), "错误文案应说清楚不对称")


func test_self_loop_is_a_warning_not_an_error() -> void:
	# 「含自身」由 WrapTopology.build(include_self=true) 产出，是**既有玩法**而不是坏数据
	# （test_wrap_topology.gd 有专项断言）⇒ 硬闸门不能拒收它，只能在提醒里说清楚。
	var built := WrapTopology.build(4, 4, WrapTopology.DIRS_ORTHO4, true, false)
	assert_true(bool(built["ok"]), "含自身的邻域应能构建")
	var audit := TopologyModel.validate(built["topology"] as Dictionary)
	assert_true(bool(audit["ok"]), "含自身的表不该被硬闸门拒收：%s" % str(audit["errors"]))
	assert_eq(int(audit["self_loop"]), 16, "4x4 含自身 = 每格一条自环")
	assert_true("；".join(audit["warnings"]).contains("自环"), "自环应出现在提醒里")


func test_canonicalize_keeps_authored_edges_and_self_loops() -> void:
	# 规范形式**只搬运、不发明**：作者的边方向照抄（单向边交给 validate 报错），自环照抄。
	var src := {
		"positions": [{"x": 0, "y": 0}, {"x": 1, "y": 0}, {"x": 2, "y": 0}],
		"neighbors": {
			"0,0": ["0,0", "1,0", "9,9"],
			"1,0": [],
			"2,0": [],
		},
	}
	var g := _grid(TopologyModel.canonicalize(src))
	assert_true(g.get_neighbors(Vector2i(0, 0)).has(Vector2i(0, 0)), "自环（含自身）必须保留")
	assert_true(g.get_neighbors(Vector2i(0, 0)).has(Vector2i(1, 0)), "合法边必须保留")
	assert_eq(g.get_neighbors(Vector2i(0, 0)).size(), 2, "盘外邻接（9,9）必须被丢掉")
	assert_eq(g.get_neighbors(Vector2i(1, 0)).size(), 0, "单向边绝不静默补成双向（交给 validate 报错）")


func test_canonicalize_symmetrizes_form1_edge_list() -> void:
	# 形式 1 的 adjacency 是**无向边表** ⇒ 重建时两个方向都必须有（这与形式 2 的纪律不同）。
	var src := {
		"positions": [{"x": 0, "y": 0}, {"x": 1, "y": 0}],
		"adjacency": [{"a": {"x": 0, "y": 0}, "b": {"x": 1, "y": 0}}],
	}
	var g := _grid(TopologyModel.canonicalize(src))
	assert_true(g.get_neighbors(Vector2i(0, 0)).has(Vector2i(1, 0)), "A 端应连到 B")
	assert_true(g.get_neighbors(Vector2i(1, 0)).has(Vector2i(0, 0)), "B 端应连回 A（无向边表）")


func test_attach_portals_adds_bidirectional_edges_and_view_meta() -> void:
	var base := {"positions": [{"x": 0, "y": 0}, {"x": 5, "y": 0}], "neighbors": {"0,0": [], "5,0": []}}
	var r := TopologyModel.attach_portals(base, [{"a": {"x": 0, "y": 0}, "b": {"x": 5, "y": 0}, "id": "A"}])
	assert_true(bool(r["ok"]), "合法虫洞应写入：%s" % str(r["errors"]))
	var topo: Dictionary = r["topology"]
	var g := _grid(topo)
	assert_true(g.get_neighbors(Vector2i(0, 0)).has(Vector2i(5, 0)), "A 端应连到 B")
	assert_true(g.get_neighbors(Vector2i(5, 0)).has(Vector2i(0, 0)), "B 端应连回 A")
	assert_eq(TopologyModel.view_kind(topo), TopologyModel.VIEW_WORMHOLE, "应自动标成虫洞呈现")
	assert_eq(g.view_meta.get("kind", ""), TopologyModel.VIEW_WORMHOLE, "BoardView 应能读到呈现元数据")
	assert_eq((g.view_meta.get("portals", []) as Array).size(), 1, "应带一条虫洞对")


func test_attach_portals_rejects_out_of_board_endpoint() -> void:
	var base := {"positions": [{"x": 0, "y": 0}], "neighbors": {"0,0": []}}
	var r := TopologyModel.attach_portals(base, [{"a": {"x": 0, "y": 0}, "b": {"x": 9, "y": 9}, "id": "X"}])
	assert_false(bool(r["ok"]), "端点不在盘上必须拒绝")
	assert_true("；".join(r["errors"]).contains("不在盘上"), "拒绝原因应可读")


func test_view_kind_infers_iso_and_wrap_without_explicit_view() -> void:
	var iso := {"positions": [{"x": 0, "y": 0}], "neighbors": {"0,0": []}, "style": "iso_cubes"}
	assert_eq(TopologyModel.view_kind(iso), TopologyModel.VIEW_IMPOSSIBLE, "iso_cubes 应推断为不可能几何")
	var wrap := _wrap_topo()
	wrap.erase("view")
	assert_eq(TopologyModel.view_kind(wrap), TopologyModel.VIEW_WRAP, "带 editor.wrap 的旧表应推断为环绕")
	wrap["view"] = {"kind": "fold", "fold": {"hinge": "x=2"}}
	assert_eq(TopologyModel.view_kind(wrap), TopologyModel.VIEW_FOLD, "显式 view.kind 优先")


func test_normalized_preserves_view_meta() -> void:
	var topo := TopologyModel.attach_portals(
		{"positions": [{"x": -1, "y": -1}, {"x": 4, "y": -1}], "neighbors": {"-1,-1": [], "4,-1": []}},
		[{"a": {"x": -1, "y": -1}, "b": {"x": 4, "y": -1}, "id": "A"}])["topology"] as Dictionary
	var g := _grid(topo)
	var norm := AdjacencyGrid.normalized(g)
	assert_eq(norm.view_meta.get("kind", ""), TopologyModel.VIEW_WORMHOLE, "归一化坐标不得丢呈现元数据")
	assert_eq(norm.get_neighbors(Vector2i(0, 0)), [Vector2i(5, 0)], "归一化后虫洞边仍在")



## ———— 落盘 / 读回保真（生成器 → JSON → 网格）————
## 这一组保护的是本仓最恨的那类 bug：**能保存，读不回**（静默丢端点、丢呈现元数据）。


func test_json_safe_view_scrubs_engine_types() -> void:
	var meta := {
		"kind": "wormhole",
		"portals": [{"a": Vector2i(1, 2), "b": Vector2i(3, 4), "id": "A"}],
	}
	var safe := TopologyModel.json_safe_view(meta)
	var back: Variant = JSON.parse_string(JSON.stringify(safe))
	assert_true(back is Dictionary, "json_safe 副本必须可 stringify + parse 往返")
	var portal: Dictionary = ((back as Dictionary)["portals"] as Array)[0]
	assert_eq(int((portal["a"] as Dictionary)["x"]), 1, "端点 x 必须保留")
	assert_eq(int((portal["a"] as Dictionary)["y"]), 2, "端点 y 必须保留")
	assert_eq(int((portal["b"] as Dictionary)["x"]), 3, "另一端 x 必须保留")


func test_wrap_topology_persists_view_and_editor_through_json() -> void:
	var built := WrapTopology.build(5, 5, ShapeGenerator.MOORE8, false, true)
	assert_true(bool(built["ok"]), "环绕拓扑应能构建")
	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(built["topology"] as Dictionary)
	var d := PuzzleGenerator._topology_to_dict(ag)
	assert_true(d.get("editor", null) is Dictionary, "落盘必须带 editor 元数据")
	assert_true(bool((d["editor"] as Dictionary).get("wrap", false)), "editor.wrap 必须为 true")
	assert_eq(String((d.get("view", {}) as Dictionary).get("kind", "")), "wrap", "view.kind 必须是 wrap")
	var back: Variant = JSON.parse_string(JSON.stringify(d))
	assert_true(back is Dictionary, "环绕盘必须能 JSON 往返")
	var ag2 := AdjacencyGrid.new()
	ag2.setup_from_topo(back as Dictionary)
	assert_true(bool(ag2.editor_meta.get("wrap", false)), "读回后 editor_meta.wrap 必须仍为 true")
	assert_eq(String(ag2.view_meta.get("kind", "")), "wrap", "读回后呈现类型必须仍是环绕")
	assert_eq(ag2.get_neighbors(Vector2i(0, 0)).size(), 8, "环绕 8 邻在往返后必须仍是 8 个邻居")
	assert_true(ag2.get_neighbors(Vector2i(0, 0)).has(Vector2i(4, 4)), "环绕应把对角折回 4,4")


func test_portal_topology_survives_json_roundtrip() -> void:
	var base := {"positions": [{"x": 0, "y": 0}, {"x": 5, "y": 0}], "neighbors": {"0,0": [], "5,0": []}}
	var r := TopologyModel.attach_portals(base, [{"a": {"x": 0, "y": 0}, "b": {"x": 5, "y": 0}, "id": "A"}])
	assert_true(bool(r["ok"]), "虫洞应能写入")
	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(r["topology"] as Dictionary)
	var d := PuzzleGenerator._topology_to_dict(ag)
	var back: Variant = JSON.parse_string(JSON.stringify(d))
	assert_true(back is Dictionary, "虫洞盘必须能 JSON 往返")
	var ag2 := AdjacencyGrid.new()
	ag2.setup_from_topo(back as Dictionary)
	assert_true(ag2.get_neighbors(Vector2i(0, 0)).has(Vector2i(5, 0)), "虫洞边读回后必须仍在")
	assert_true(ag2.get_neighbors(Vector2i(5, 0)).has(Vector2i(0, 0)), "虫洞边读回后必须双向")
	assert_eq(String(ag2.view_meta.get("kind", "")), "wormhole", "读回后呈现类型必须是虫洞")
	assert_eq((ag2.view_meta.get("portals", []) as Array).size(), 1, "读回后仍应恰有一条虫洞对")
