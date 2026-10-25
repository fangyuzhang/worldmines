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
