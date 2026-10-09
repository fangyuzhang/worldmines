# test_wormhole_levels.gd —— 官方虫洞关（levels/wormhole_*.json）的内容门禁。
#
# 守两件事（都是"落盘了但玩家玩不到"的典型断法）：
#   ① 拓扑自述里必须有 view.kind=wormhole 与至少一对 portals —— 否则呈现层无提示，
#      玩家只会觉得线索数错了；
#   ② 每一对虫洞端点都必须**在盘上**、且邻接表里**真的双向连通** —— 否则关卡自述的管子
#      与引擎实际用的图不是同一根（正是 TopologyModel 存在的理由）。
# 另外每一关都必须能被 LevelLoader 真载入（"能保存，读不回"是本仓最恨的 bug 类型）。
extends GutTest

const SHAPE_KIND := "虫洞"


## 收集 levels/wormhole_*.json 的绝对 res:// 路径。
func _paths() -> Array[String]:
	var out: Array[String] = []
	for path in LevelLoader.list_levels():
		if path.get_file().begins_with("wormhole_") and path.get_file().ends_with(".json"):
			out.append(path)
	out.sort()
	return out


func test_wormhole_family_exists_and_is_loaded_cleanly() -> void:
	var paths := _paths()
	assert_gt(paths.size(), 0, "应有官方虫洞关")
	for path in paths:
		var board: Board = LevelLoader.load_level(path)
		assert_not_null(board, "%s 应能载入" % path.get_file())
		if board == null:
			continue
		assert_true(board.grid is AdjacencyGrid, "%s 应走邻接表网格（带 topology）" % path.get_file())
		if not (board.grid is AdjacencyGrid):
			continue
		var ag := board.grid as AdjacencyGrid
		assert_eq(str(ag.view_meta.get("kind", "")), TopologyModel.VIEW_WORMHOLE,
			"%s 的呈现类型必须是虫洞" % path.get_file())
		var pairs: Array = ag.view_meta.get("portals", [])
		assert_gt(pairs.size(), 0, "%s 至少应有一条虫洞" % path.get_file())
		# 每对端点：在盘上 + 双向连通
		for pr: Dictionary in pairs:
			var a: Vector2i = pr["a"]
			var b: Vector2i = pr["b"]
			assert_true(ag.in_board(a), "%s：端点 %s 必须在盘上" % [path.get_file(), str(a)])
			assert_true(ag.in_board(b), "%s：端点 %s 必须在盘上" % [path.get_file(), str(b)])
			assert_true(ag.get_neighbors(a).has(b), "%s：%s -> %s 应有虫洞边" % [path.get_file(), str(a), str(b)])
			assert_true(ag.get_neighbors(b).has(a), "%s：%s -> %s 应有虫洞边" % [path.get_file(), str(b), str(a)])


func test_wormhole_levels_declare_shape_kind_and_read_back_ports() -> void:
	var checked := 0
	for path in _paths():
		var f := FileAccess.open(path, FileAccess.READ)
		assert_not_null(f, "应能读 %s" % path.get_file())
		if f == null:
			continue
		var d: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		assert_true(d is Dictionary, "%s 应是合法 JSON 对象" % path.get_file())
		if not (d is Dictionary):
			continue
		var lv: Dictionary = d
		assert_eq(str(lv.get("shape_kind", "")), SHAPE_KIND, "%s 的 shape_kind 应为虫洞（选关页卡片标签）" % path.get_file())
		var topo: Dictionary = lv.get("topology", {})
		assert_eq(TopologyModel.view_kind(topo), TopologyModel.VIEW_WORMHOLE,
			"%s 的拓扑应判成虫洞呈现" % path.get_file())
		var pairs := TopologyModel.portal_pairs(topo)
		assert_gt(pairs.size(), 0, "%s 至少应声明一条虫洞" % path.get_file())
		# 拓扑自述本身必须过安全门（盘外/单向/重复一律不放过）
		var audit := TopologyModel.validate(topo)
		assert_true(bool(audit["ok"]), "%s 的拓扑应过安全门：%s" % [path.get_file(), str(audit["errors"])])
		checked += 1
	assert_gt(checked, 0, "应至少核到一关")
