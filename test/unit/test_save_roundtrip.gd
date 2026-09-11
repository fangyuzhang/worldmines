# test_save_roundtrip.gd —— 存档往返（文档 §4.4 / §4.2.1）
extends GutTest


func test_save_dict_roundtrip() -> void:
	var sd := SaveData.new()
	sd.revealed_cells = [Vector2i(1, 2), Vector2i(3, 4)]
	sd.flagged_cells = [Vector2i(0, 0)]
	sd.timer_seconds = 12.5
	sd.mine_positions = [Vector2i(2, 2), Vector2i(4, 4)]
	sd.seed_value = 42
	sd.metadata = {"level_id": "classic_01"}

	var sd2 := SaveData.new()
	sd2.from_dict(sd.to_dict())

	assert_eq(sd2.revealed_cells, sd.revealed_cells, "翻开格恢复")
	assert_eq(sd2.flagged_cells, sd.flagged_cells, "标记格恢复")
	assert_almost_eq(sd2.timer_seconds, 12.5, 0.001, "计时恢复")
	assert_eq(sd2.mine_positions, sd.mine_positions, "雷位恢复")
	assert_eq(sd2.seed_value, 42, "种子恢复")
	assert_eq(sd2.metadata["level_id"], "classic_01", "元数据恢复")


func test_save_file_roundtrip() -> void:
	var sd := SaveData.new()
	sd.revealed_cells = [Vector2i(0, 1), Vector2i(2, 3)]
	sd.timer_seconds = 3.25
	sd.mine_positions = [Vector2i(1, 1)]
	sd.seed_value = 7
	assert_true(sd.save(), "保存成功")

	var sd2 := SaveData.new()
	assert_true(sd2.load(), "加载成功")
	assert_eq(sd2.revealed_cells, sd.revealed_cells, "文件往返：翻开格")
	assert_eq(sd2.mine_positions, sd.mine_positions, "文件往返：雷位")
	assert_almost_eq(sd2.timer_seconds, 3.25, 0.001, "文件往返：计时")
	assert_eq(sd2.seed_value, 7, "文件往返：种子")
