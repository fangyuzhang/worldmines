# test_snapshot_quota.gd —— 历史快照：内容哈希去重 + 全局磁盘配额淘汰
# 对应任务 2（文档 F②④）：
#   ① 同内容两次保存 → 只留一份（不重复落盘）
#   ② 写超配额 → 最旧的被删、最新的存活，且**当前存档主文件绝不被误删**
extends GutTest

const MAIN := "user://save.json"
const TEMP := "user://save_temp.json"
const BAK := "user://save.json.bak"


func before_each() -> void:
	SaveCoordinator.snapshot_quota_bytes = SaveCoordinator.SNAPSHOT_QUOTA_BYTES
	SaveCoordinator.clear_snapshots()
	_rm(MAIN)
	_rm(TEMP)
	_rm(BAK)


func after_each() -> void:
	SaveCoordinator.snapshot_quota_bytes = SaveCoordinator.SNAPSHOT_QUOTA_BYTES
	SaveCoordinator.clear_snapshots()
	_rm(MAIN)
	_rm(TEMP)
	_rm(BAK)


# ① 同内容两次保存 → 只留一份
func test_same_content_written_once() -> void:
	var d := {"schema": 1, "size": {"rows": 9, "cols": 9}, "mines": [[1, 2], [3, 4]]}
	var p1 := SaveCoordinator.write_snapshot(d)
	var p2 := SaveCoordinator.write_snapshot(d.duplicate(true))
	assert_ne(p1, "", "快照应成功落盘")
	assert_eq(p2, p1, "同内容第二次写入应命中去重（返回同一路径）")
	assert_eq(SaveCoordinator.list_snapshots().size(), 1, "同内容两次保存只留一份")

	# 键序不同但内容相同也应去重（哈希基于键排序后的规范化 JSON）
	var reordered := {"mines": [[1, 2], [3, 4]], "size": {"cols": 9, "rows": 9}, "schema": 1}
	assert_eq(SaveCoordinator.write_snapshot(reordered), p1, "键序不同、内容相同应去重")
	assert_eq(SaveCoordinator.list_snapshots().size(), 1)


# ② 超配额 → 删最旧、留最新；主档/TEMP 绝不被碰
func test_quota_prunes_oldest_and_spares_main_save() -> void:
	# 先造出一份"当前存档主文件"与 TEMP（崩溃标志），淘汰过程必须完全绕开它们
	_write_file(MAIN, "MAIN-PAYLOAD")
	_write_file(TEMP, "TEMP-PAYLOAD")

	SaveCoordinator.snapshot_quota_bytes = 250  # 每份 JSON ≈96B ⇒ 只容得下 2 份
	var paths: Array = []
	for i in 5:
		paths.append(SaveCoordinator.write_snapshot({"i": i, "pad": "x".repeat(80)}))

	var snaps := SaveCoordinator.list_snapshots()
	assert_true(snaps.size() < 5, "超配额应淘汰旧快照")
	assert_true(SaveCoordinator.snapshot_total_bytes() <= SaveCoordinator.snapshot_quota_bytes,
			"快照总量应被压到配额以内")
	assert_true(snaps.has(paths[4]), "最新一份必须存活")
	assert_false(snaps.has(paths[0]), "最旧一份应被删除")

	# 关键断言：当前存档主文件绝不被误删
	assert_true(FileAccess.file_exists(MAIN), "当前存档主文件绝不能被误删")
	assert_true(FileAccess.file_exists(TEMP), "TEMP 也不能被误删")
	assert_eq(_read_file(MAIN), "MAIN-PAYLOAD", "主档内容不得被改动")


# 清空快照不得动主档
func test_clear_snapshots_does_not_touch_main() -> void:
	_write_file(MAIN, "MAIN")
	SaveCoordinator.write_snapshot({"a": 1})
	SaveCoordinator.clear_snapshots()
	assert_eq(SaveCoordinator.list_snapshots().size(), 0, "快照应清空")
	assert_true(FileAccess.file_exists(MAIN), "清快照不得动主档")


# 测试辅助
func _write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read_file(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
