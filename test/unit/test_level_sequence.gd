# test_level_sequence.gd —— 生成关卡序列（ui/level_sequence.gd）
# 该模块是「终局→下一关」与「选关页生成」的共享事实来源，
# 路径解析 / 越界 / 焦点交接都必须锁死，否则 game_over 会跳到错误的关卡。
extends GutTest


func test_parse_path_valid() -> void:
	var p := LevelSequence.parse_path("user://gen_levels/mx_4n_8_2.json")
	assert_eq(str(p.get("mode", "")), "mx_4n", "带下划线的变体 id 必须整段保留")
	assert_eq(int(p.get("size", 0)), 8)
	assert_eq(int(p.get("idx", -1)), 2)


func test_parse_path_rejects_non_gen_level() -> void:
	assert_true(LevelSequence.parse_path("res://levels/classic_01.json").is_empty(),
			"手工关不在 gen 序列里（size/idx 位不足）")
	assert_true(LevelSequence.parse_path("user://gen_levels/classic_5.json").is_empty(),
			"缺少序号位的路径必须拒绝")


func test_next_level_path_increments_index() -> void:
	var s := LevelSequence.next_level_path("user://gen_levels/sc_6_0.json")
	assert_eq(s, "user://gen_levels/sc_6_1.json", "下一关 = 同变体同尺寸 +1 号")


func test_next_level_path_empty_at_last() -> void:
	var last := LevelSequence.LEVELS_PER_SET - 1
	var s := LevelSequence.next_level_path("user://gen_levels/sc_6_%d.json" % last)
	assert_eq(s, "", "已是本套最后一关 → 没有下一关")
	assert_false(LevelSequence.has_next("user://gen_levels/sc_6_%d.json" % last))


func test_level_key_matches_level_select_convention() -> void:
	assert_eq(LevelSequence.level_key("4c", 9, 1), "gen://4c/9/1",
			"必须与 ui/level_select._level_key 的口径一致")


func test_focus_handoff_is_once_only() -> void:
	LevelSequence.request_focus("dt_loopruns", 7)
	var got := LevelSequence.take_focus()
	assert_eq(str(got.get("mode", "")), "dt_loopruns")
	assert_eq(int(got.get("size", 0)), 7)
	assert_true(LevelSequence.take_focus().is_empty(),
			"交接意图领取后即清空（避免下次进选关页重复展开弹窗）")
