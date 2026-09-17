# test_progress_store.gd —— 通关进度持久化（user://progress.json）
# 用例会临时占用真实进度文件：before_each 备份、after_each 还原，绝不污染玩家数据。
extends GutTest

const LEVEL_A := "res://levels/classic_01.json"
const LEVEL_B := "res://levels/classic_02.json"

var _backup: String = ""
var _backup_exists: bool = false


func before_each() -> void:
	_backup = ""
	_backup_exists = FileAccess.file_exists(ProgressStore.PATH)
	if _backup_exists:
		var f := FileAccess.open(ProgressStore.PATH, FileAccess.READ)
		_backup = f.get_as_text()
		f.close()
	ProgressStore.clear_all()


func after_each() -> void:
	if _backup_exists:
		var f := FileAccess.open(ProgressStore.PATH, FileAccess.WRITE)
		f.store_string(_backup)
		f.close()
	else:
		var d := DirAccess.open("user://")
		if d != null and d.file_exists("progress.json"):
			d.remove("progress.json")
	ProgressStore.reset_cache()


# P1：记录通关 → cleared + 最佳用时
func test_p1_record_clear() -> void:
	assert_false(ProgressStore.is_cleared(LEVEL_A), "初始未通关")
	ProgressStore.record_clear(LEVEL_A, 30.0)
	assert_true(ProgressStore.is_cleared(LEVEL_A), "记录后应已通关")
	assert_almost_eq(ProgressStore.best_time(LEVEL_A), 30.0, 0.001)


# P2：最佳用时取更小值
func test_p2_best_time_keeps_minimum() -> void:
	ProgressStore.record_clear(LEVEL_A, 30.0)
	ProgressStore.record_clear(LEVEL_A, 12.5)
	assert_almost_eq(ProgressStore.best_time(LEVEL_A), 12.5, 0.001, "最佳应为更小值")
	ProgressStore.record_clear(LEVEL_A, 40.0)
	assert_almost_eq(ProgressStore.best_time(LEVEL_A), 12.5, 0.001, "更差成绩不覆盖最佳")


# P3：失败尝试只累加次数，不判通关
func test_p3_attempt_does_not_clear() -> void:
	ProgressStore.record_attempt(LEVEL_B)
	ProgressStore.record_attempt(LEVEL_B)
	assert_false(ProgressStore.is_cleared(LEVEL_B), "尝试不算通关")
	assert_eq(ProgressStore.plays(LEVEL_B), 2, "尝试次数应累加")
	assert_almost_eq(ProgressStore.best_time(LEVEL_B), -1.0, 0.001, "未通关无最佳用时")


# P4：落盘后重读仍在（reset_cache 强制重读磁盘）
func test_p4_persists_across_cache_reset() -> void:
	ProgressStore.record_clear(LEVEL_A, 9.0)
	ProgressStore.reset_cache()
	assert_true(ProgressStore.is_cleared(LEVEL_A), "应从磁盘恢复进度")
	assert_almost_eq(ProgressStore.best_time(LEVEL_A), 9.0, 0.001)


# P5：clear_all 清空，且 cleared_count 正确
func test_p5_clear_all_and_count() -> void:
	ProgressStore.record_clear(LEVEL_A, 9.0)
	ProgressStore.record_clear(LEVEL_B, 8.0)
	assert_eq(ProgressStore.cleared_count(), 2)
	ProgressStore.clear_all()
	assert_eq(ProgressStore.cleared_count(), 0, "clear_all 应清空")


# P7：跳过本关 —— 记为 skipped，但**不算通关**
# （跳过若写成 cleared，通关统计与最佳用时都会失真：历史坑见 level_select._mock_cleared）
func test_p7_skip_is_not_clear() -> void:
	ProgressStore.record_skip(LEVEL_A)
	assert_true(ProgressStore.is_skipped(LEVEL_A), "应记为已跳过")
	assert_false(ProgressStore.is_cleared(LEVEL_A), "跳过不算通关")
	assert_almost_eq(ProgressStore.best_time(LEVEL_A), -1.0, 0.001, "跳过不产生最佳用时")
	assert_eq(ProgressStore.cleared_count(), 0, "跳过不计入通关数")
	ProgressStore.reset_cache()
	assert_true(ProgressStore.is_skipped(LEVEL_A), "跳过状态应落盘")


# P8：跳过后回头打通 → skipped 自动清除，转为正常通关
func test_p8_clear_after_skip_drops_flag() -> void:
	ProgressStore.record_skip(LEVEL_A)
	ProgressStore.record_clear(LEVEL_A, 5.0)
	assert_true(ProgressStore.is_cleared(LEVEL_A))
	assert_false(ProgressStore.is_skipped(LEVEL_A), "通关后不应再显示为「跳过」")
	assert_eq(ProgressStore.cleared_count(), 1, "此时才计入通关数")


# P9：键一致性 —— 写进度与读进度必须是同一个键
# 历史 bug：GameSession 写 user://gen_levels/*.json，选关页与 has_next 读 gen://*，
# 表现为「通关了却不打勾、下一关一直锁着、终局页的『下一关』永不出现」。
func test_p9_session_win_writes_sequence_key() -> void:
	GameSession.level_path = "user://gen_levels/classic_5_0.json"
	GameSession.elapsed = 3.0
	GameSession.state = GameSession.State.PLAYING
	GameSession.board = Board.new()
	GameSession._finish(true)
	assert_true(ProgressStore.is_cleared(LevelSequence.level_key("classic", 5, 0)),
			"通关应写进 gen:// 键（选关页与 has_next 正是按这个键读的）")
	assert_true(LevelSequence.has_next("user://gen_levels/classic_5_0.json"),
			"通关后 has_next 应为真 → 终局页的「下一关」才会出现")
	GameSession.board = null
	GameSession.state = GameSession.State.IDLE


# P10：旧键迁移 —— 早期版本按文件路径记进度，加载时应搬到序列键（老存档不能丢）
func test_p10_migrates_legacy_path_keys() -> void:
	ProgressStore.record_clear("user://gen_levels/classic_6_1.json", 11.0)
	ProgressStore.reset_cache()
	var key := LevelSequence.level_key("classic", 6, 1)
	assert_true(ProgressStore.is_cleared(key), "旧的文件路径键应在加载时迁移到 gen:// 键")
	assert_almost_eq(ProgressStore.best_time(key), 11.0, 0.001, "迁移不得丢最佳用时")
	assert_false(ProgressStore.is_cleared("user://gen_levels/classic_6_1.json"),
			"迁移后旧键应被移除（幂等）")


# P6：GameSession 通关接线（_finish(true) → 写入进度）
func test_p6_session_win_records_progress() -> void:
	GameSession.level_path = LEVEL_A
	GameSession.elapsed = 7.5
	GameSession.state = GameSession.State.PLAYING
	var board := Board.new()
	GameSession.board = board
	GameSession._finish(true)
	assert_true(ProgressStore.is_cleared(LEVEL_A), "通关应写入进度")
	assert_almost_eq(ProgressStore.best_time(LEVEL_A), 7.5, 0.001)
	GameSession.board = null
	GameSession.state = GameSession.State.IDLE
