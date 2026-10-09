extends GutTest

## LevelLoader 的拓扑硬闸门：坏图不得静默进入对局。

func _base(topo: Dictionary, mines: Array = [], revealed: Array = [], total: int = 0) -> Dictionary:
	return {
		"name": "拓扑闸门测试",
		"size": {"rows": 3, "cols": 3},
		"total_mines": total,
		"mines": mines,
		"revealed": revealed,
		"topology": topo,
	}


func _valid_topo() -> Dictionary:
	return {
		"positions": [{"x": 0, "y": 0}, {"x": 1, "y": 0}, {"x": 2, "y": 0}],
		"neighbors": {"0,0": ["1,0"], "1,0": ["0,0", "2,0"], "2,0": ["1,0"]},
	}


func test_valid_topology_loads() -> void:
	var b := LevelLoader._validate_and_build(_base(_valid_topo()), "test://topo-valid")
	assert_not_null(b, "合法拓扑应载入")
	if b != null:
		assert_eq(b.grid.cell_count(), 3, "应只有拓扑上的 3 格")


func test_asymmetric_topology_is_rejected() -> void:
	var topo := _valid_topo()
	(topo["neighbors"] as Dictionary)["1,0"] = ["2,0"]   # 0->1 仍存在，1->0 被删
	var b := LevelLoader._validate_and_build(_base(topo), "test://topo-asym")
	assert_null(b, "单向邻接应被硬闸门拒绝")
	assert_push_error_count(1)


func test_mine_outside_topology_is_rejected() -> void:
	var topo := _valid_topo()
	var b := LevelLoader._validate_and_build(
		_base(topo, [{"r": 2, "c": 2}], [], 1), "test://topo-mine-oob")
	assert_null(b, "拓扑盘外的雷位应被拒绝")
	assert_push_error_count(1)


func test_revealed_outside_topology_is_rejected() -> void:
	var topo := _valid_topo()
	var b := LevelLoader._validate_and_build(
		_base(topo, [], [{"r": 2, "c": 2}], 0), "test://topo-reveal-oob")
	assert_null(b, "拓扑盘外的初始翻开格应被拒绝")
	assert_push_error_count(1)


func test_mine_count_uses_topology_cell_count_not_bounding_box() -> void:
	var topo := _valid_topo()   # 包围盒 3x3，但逻辑只有 3 格
	var b := LevelLoader._validate_and_build(
		_base(topo, [{"r": 0, "c": 0}, {"r": 0, "c": 1}, {"r": 0, "c": 2}], [], 3),
		"test://topo-count")
	assert_null(b, "雷数等于逻辑格数应被拒绝（至少要留一个非雷格）")
	assert_push_error_count(1)
