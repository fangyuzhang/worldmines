extends GutTest

## ? 格区间口径统一（v2.9.3）
##
## 历史上两类关卡口径不一：手工关写 `[0, 8]`（几乎无信息），生成关写 `[1, 8]`（含「≥1」）。
## 同为「?」符号但信息量差很多 → 难度不可比。
##
## 现统一为 `[1, hi]`，在**加载时归一化**（不改关卡数据文件）：
## 真值 ≥1 时把下界抬到 1；真值确为 0 时保持原区间并告警（抬高会让该关卡无解）。


func test_manual_level_zero_lower_bound_is_normalized() -> void:
	# classic_01 的 ? 格 @(2,0) 数据里写的是 [0, 8]
	var jf := FileAccess.open("res://levels/classic_01.json", FileAccess.READ)
	assert_true(jf != null, "关卡文件存在")
	var level: Variant = JSON.parse_string(jf.get_as_text())
	jf.close()
	var b := Board.new()
	b.load_level(level)
	var cell: Cell = b.grid.get_cell(Vector2i(0, 2))
	assert_true(cell.is_hidden_clue(), "(2,0) 应是 ? 格")
	assert_eq(cell.hidden_interval.x, 1, "真值 ≥1 的 ? 格下界应被归一为 1")
	assert_eq(cell.hidden_interval.y, 8, "上界不变")


func test_zero_value_hidden_clue_keeps_interval() -> void:
	# 真值为 0 的 ? 格：抬高下界会让盘面无解，故必须保持原区间（宁可口径不统一，不可弄坏可解性）
	var level := {
		"size": {"rows": 3, "cols": 3},
		"total_mines": 0,
		"mines": [],
		"revealed": [{"r": 1, "c": 1, "interval": [0, 8]}],
	}
	var b := Board.new()
	b.load_level(level)
	var cell: Cell = b.grid.get_cell(Vector2i(1, 1))
	assert_true(cell.is_hidden_clue(), "中心应是 ? 格")
	assert_eq(cell.hidden_interval, Vector2i(0, 8), "真值为 0 时必须保留 [0,8]（否则无解）")


func test_generated_interval_is_upper_bound_only() -> void:
	# 生成关本来就写 [1, hi]，归一化不应把上界也改掉
	var level := {
		"size": {"rows": 3, "cols": 3},
		"total_mines": 1,
		"mines": [{"r": 0, "c": 0}],
		"revealed": [{"r": 1, "c": 1, "interval": [1, 8]}],
	}
	var b := Board.new()
	b.load_level(level)
	var cell: Cell = b.grid.get_cell(Vector2i(1, 1))
	assert_eq(cell.hidden_interval, Vector2i(1, 8), "已统一的区间应原样保留")
