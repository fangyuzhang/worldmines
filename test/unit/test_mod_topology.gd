# test_mod_topology.gd —— P0-A：Mod 声明 board.json（通用邻接表）→ 异形生成
# 关键原则：拓扑是「通用邻接表 {positions, adjacency}」，任意形状（三角形/六边形/自定义）均可，
# 平台不做形状枚举。
extends GutTest

const TEST_MOD_DIR := "user://_mod_topo_test"


func after_each() -> void:
	var d := DirAccess.open(TEST_MOD_DIR)
	if d != null:
		for fname in ["manifest.json", "board.json", "clue.json"]:
			d.remove(fname)
		d.remove("defs")  # 目录删除失败无害（空目录遗留由系统清理）


## 六边形 7 格：盘心 + 6 邻 = 标准蜂窝盘（轮图 W6：6 环格两两成 C6 环、各连盘心）。
## 以盘心为原点 ⇒ 含负坐标（专门覆盖 AdjacencyGrid.normalized 的归零路径）；
## 平移 (+1,+1) 后与 ShapeGenerator.build_hex(3) 逐边同构（test_shape_generator.gd 有门禁）。
const HEX_BOARD := {
	"positions": [
		{"x": 0, "y": 0},
		{"x": 1, "y": 0}, {"x": -1, "y": 0},
		{"x": 0, "y": 1}, {"x": 0, "y": -1},
		{"x": 1, "y": -1}, {"x": -1, "y": 1},
	],
	"adjacency": [
		{"a": {"x": 0, "y": 0}, "b": {"x": 1, "y": 0}},
		{"a": {"x": 0, "y": 0}, "b": {"x": -1, "y": 0}},
		{"a": {"x": 0, "y": 0}, "b": {"x": 0, "y": 1}},
		{"a": {"x": 0, "y": 0}, "b": {"x": 0, "y": -1}},
		{"a": {"x": 0, "y": 0}, "b": {"x": 1, "y": -1}},
		{"a": {"x": 0, "y": 0}, "b": {"x": -1, "y": 1}},
		{"a": {"x": 1, "y": 0}, "b": {"x": 1, "y": -1}},
		{"a": {"x": 1, "y": -1}, "b": {"x": 0, "y": -1}},
		{"a": {"x": 0, "y": -1}, "b": {"x": -1, "y": 0}},
		{"a": {"x": -1, "y": 0}, "b": {"x": -1, "y": 1}},
		{"a": {"x": -1, "y": 1}, "b": {"x": 0, "y": 1}},
		{"a": {"x": 0, "y": 1}, "b": {"x": 1, "y": 0}},
	]
}


func _write_mod() -> void:
	DirAccess.make_dir_recursive_absolute(TEST_MOD_DIR)
	# manifest（def runtime）
	var m := {"id": "topo.test", "version": "1.0.0", "entry": {"runtime": "def", "path": "defs"}}
	var mf := FileAccess.open(TEST_MOD_DIR.path_join("manifest.json"), FileAccess.WRITE)
	mf.store_string(JSON.stringify(m))
	mf.close()
	# board.json（通用邻接表）
	var bf := FileAccess.open(TEST_MOD_DIR.path_join("board.json"), FileAccess.WRITE)
	bf.store_string(JSON.stringify(HEX_BOARD))
	bf.close()
	# defs/classic.json（一个计数型线索）
	DirAccess.make_dir_recursive_absolute(TEST_MOD_DIR.path_join("defs"))
	var df := FileAccess.open(TEST_MOD_DIR.path_join("defs").path_join("clue.json"), FileAccess.WRITE)
	df.store_string('{"defName": "TopoClue", "type": "clue", "window": "n8", "aggregate": "sum", "value_range": [0, 6], "empty_value": 0}')
	df.close()


func test_mod_board_load_and_generate() -> void:
	var api := preload("res://core/mod_api.gd").new()
	_write_mod()
	var r := api.load_mod(TEST_MOD_DIR)
	assert_true(r.get("ok", false), "带 board.json 的 mod 应加载成功: %s" % str(r.get("reason", "")))
	if not r.get("ok", false):
		return
	# get_board 返回拓扑
	var board: Dictionary = api.get_board("topo.test")
	assert_false(board.is_empty(), "get_board 应返回拓扑")
	assert_eq(board["positions"].size(), 7, "六边形应 7 格")
	# 生成：Def 线索 + 拓扑（坐标归一化，六边形含负坐标）
	var topo := AdjacencyGrid.new()
	topo.setup_from_topo(board)
	topo = AdjacencyGrid.normalized(topo)
	var gen := PuzzleGenerator.new()
	var level := {}
	for seed in range(1, 11):
		level = gen.generate_with_engine(api.defs, "TopoClue", "", Vector2i(3, 3), 1, seed, topo)
		if not level.is_empty():
			break
	assert_false(level.is_empty(), "六边形拓扑应能生成关卡")
	if level.is_empty():
		return
	assert_true(level.has("topology"), "关卡应落盘 topology 字段")
	# Board 加载 → AdjacencyGrid + 7 格
	var b := Board.new()
	b.load_level(level)
	assert_true(b.grid is AdjacencyGrid, "Board 应重建异形拓扑")
	assert_eq(b.grid.cell_count(), 7, "异形棋盘应 7 格")
	# 洞格非雷：包围盒 3×3=9，去掉 2 个洞格 → 7 雷位里 1 雷，洞格必非雷
	var mines := 0
	for m in b.get_mine_positions():
		mines += 1
	assert_eq(mines, 1, "7 格棋盘 1 雷")
	# 卸载清理
	api.unload_mod("topo.test")


func test_mod_board_fallback_rect() -> void:
	var api := preload("res://core/mod_api.gd").new()
	# 无 board.json 的 mod → get_board 返回空
	DirAccess.make_dir_recursive_absolute(TEST_MOD_DIR)
	var m := {"id": "rect.test", "version": "1.0.0", "entry": {"runtime": "def", "path": "defs"}}
	var mf := FileAccess.open(TEST_MOD_DIR.path_join("manifest.json"), FileAccess.WRITE)
	mf.store_string(JSON.stringify(m))
	mf.close()
	DirAccess.make_dir_recursive_absolute(TEST_MOD_DIR.path_join("defs"))
	var r := api.load_mod(TEST_MOD_DIR)
	assert_true(r.get("ok", false), "无 board 的 mod 应加载成功")
	assert_true(api.get_board("rect.test").is_empty(), "无 board.json 应返回空拓扑（矩形回退）")
	api.unload_mod("rect.test")
