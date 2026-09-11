# test_player_view.gd —— PlayerView 双视角隔离测试（文档 23 号 §7 / 21 号 R30）
extends GutTest


func _make_board() -> Board:
	var b := Board.new()
	b.load_level({
		"size": {"rows": 3, "cols": 3},
		"total_mines": 2,
		"mines": [{"r": 0, "c": 0}, {"r": 1, "c": 1}],
		"revealed": [
			{"r": 2, "c": 2, "value": 2},
			{"r": 0, "c": 2, "interval": [0, 1]},
		],
	})
	return b


func test_from_board_state() -> void:
	var view := PlayerView.from_board(_make_board())
	assert_eq(view.get_state(Vector2i(2, 2)), PlayerView.STATE_REVEALED, "翻开格应为 REVEALED")
	assert_eq(view.get_state(Vector2i(0, 0)), PlayerView.STATE_HIDDEN, "未翻开雷格应为 HIDDEN")
	assert_eq(view.get_clue(Vector2i(2, 2)), 1, "翻开格线索值应正确（(2,2) 邻域仅 1 雷）")
	# v2.9.3 区间口径统一：真值 ≥1 的 ? 格下界归一为 1（原数据写 [0,1]）
	assert_eq(view.get_interval(Vector2i(2, 0)), Vector2i(1, 1), "? 格区间应正确（口径已统一）")
	assert_eq(view.size(), Vector2i(3, 3), "尺寸应正确")


func test_player_constraint() -> void:
	var view := PlayerView.from_board(_make_board())
	assert_eq(view.get_player_constraint(Vector2i(2, 2))["type"], "equality", "普通翻开格 equality")
	assert_eq(view.get_player_constraint(Vector2i(2, 0))["type"], "interval", "? 格 interval")
	assert_eq(view.get_player_constraint(Vector2i(0, 0))["type"], "none", "未翻开 none")


func test_counts() -> void:
	var view := PlayerView.from_board(_make_board())
	assert_eq(view.total_mines(), 2, "总雷数应正确")
	assert_eq(view.revealed_count(), 2, "翻开格数应正确")
	assert_eq(view.flag_count(), 0, "旗数应正确")
	assert_eq(view.remaining_mines(), 2, "剩余雷数 = 总雷数 - 旗数")


func test_no_mine_leak() -> void:
	var view := PlayerView.from_board(_make_board())
	# 结构上不存在判负相关接口（R30：任何可推出雷位的 API 都是安全漏洞）
	assert_false(view.has_method("is_mine"), "PlayerView 不得有 is_mine")
	assert_false(view.has_method("get_mine_positions"), "PlayerView 不得有 get_mine_positions")
	assert_false("is_mine" in view, "PlayerView 不得有 is_mine 属性")
	assert_false("mine_positions" in view, "PlayerView 不得有 mine_positions 属性")


func test_flagged() -> void:
	var b := _make_board()
	b.toggle_flag(Vector2i(0, 0))  # HIDDEN -> FLAGGED
	var view := PlayerView.from_board(b)
	assert_eq(view.flag_count(), 1, "插旗后旗数应为 1")
	assert_true(view.is_flagged(Vector2i(0, 0)), "插旗格 is_flagged 应 true")
	assert_eq(view.remaining_mines(), 1, "剩余雷数应减 1")
