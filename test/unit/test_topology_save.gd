extends GutTest

## 异形（邻接表）棋盘存档回归（v2.9.3 交叉检查修复）：
## AdjacencyGrid.size() 是包围盒——按 size 双重循环遍历会把洞格的 get_cell()==null
## 当 Cell 用而报错（save_coordinator/hud/game_session 三处已改用 all_positions/null 守卫）。
## 本测试构造 3×3 包围盒 + 2 洞格（7 真实格）→ 存档必须成功且只含真实格。

## 归一化后的六边形 7 格（包围盒 3×3，洞格 = (0,0) 与 (2,2)）。
const HEX_POSITIONS := [
	{"x": 1, "y": 1},
	{"x": 2, "y": 1}, {"x": 0, "y": 1},
	{"x": 1, "y": 2}, {"x": 1, "y": 0},
	{"x": 2, "y": 0}, {"x": 0, "y": 2},
]
const HEX_ADJACENCY := [
	{"a": {"x": 1, "y": 1}, "b": {"x": 2, "y": 1}},
	{"a": {"x": 1, "y": 1}, "b": {"x": 0, "y": 1}},
	{"a": {"x": 1, "y": 1}, "b": {"x": 1, "y": 2}},
	{"a": {"x": 1, "y": 1}, "b": {"x": 1, "y": 0}},
	{"a": {"x": 1, "y": 1}, "b": {"x": 2, "y": 0}},
	{"a": {"x": 1, "y": 1}, "b": {"x": 0, "y": 2}},
	{"a": {"x": 2, "y": 1}, "b": {"x": 2, "y": 0}},
	{"a": {"x": 0, "y": 1}, "b": {"x": 0, "y": 2}},
	{"a": {"x": 1, "y": 2}, "b": {"x": 2, "y": 0}},
	{"a": {"x": 1, "y": 2}, "b": {"x": 0, "y": 2}},
	{"a": {"x": 1, "y": 0}, "b": {"x": 2, "y": 0}},
	{"a": {"x": 1, "y": 0}, "b": {"x": 0, "y": 2}},
]


func _make_topo_level() -> Dictionary:
	return {
		"size": {"rows": 3, "cols": 3},
		"total_mines": 1,
		"mines": [{"r": 1, "c": 2}],           # 中心 (1,1) 的右邻为雷
		"revealed": [{"r": 1, "c": 1}],        # 中心已翻开（邻域计数 1）
		"topology": {"positions": HEX_POSITIONS, "adjacency": HEX_ADJACENCY},
	}


func after_each() -> void:
	SaveCoordinator.clear()


func test_topology_board_loads_7_cells() -> void:
	var b := Board.new()
	b.load_level(_make_topo_level())
	assert_true(b.grid is AdjacencyGrid, "应重建异形拓扑")
	assert_eq(b.grid.cell_count(), 7, "7 真实格")
	assert_false(b.grid.in_board(Vector2i(0, 0)), "洞格不在棋盘内")
	assert_eq(b.grid.get_cell(Vector2i(0, 0)), null, "洞格 get_cell 为 null")


func test_topology_save_does_not_crash() -> void:
	# 修复前：save() 按包围盒双重循环 → 洞格 get_cell()==null.state → 报错。
	var b := Board.new()
	b.load_level(_make_topo_level())
	SaveCoordinator.save(b, 12.0, "test://topo")
	assert_true(FileAccess.file_exists(SaveCoordinator.MAIN), "异形存档应成功写入")
	var d: Dictionary = SaveCoordinator.load_save()
	assert_false(d.is_empty(), "存档应可读回")
	# 存档格必须全部是真实格（不含洞格坐标）
	var holes := 0
	for p in d.get("revealed_cells", []):
		var pos := Vector2i(int(p[1]), int(p[0]))
		if not b.grid.in_board(pos):
			holes += 1
	assert_eq(holes, 0, "存档不得含洞格（修复前无法走到这里）")
	assert_eq(d.get("mine_positions", []).size(), 1, "雷位数一致")
