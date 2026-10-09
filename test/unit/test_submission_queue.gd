extends GutTest

## 认证提交入口的本地队列（`core/submission_queue.gd`）单测。
## 钉住的不变量：
##   ① 文件不存在 ⇒ **空队列**（不是错误）；坏档 / 结构不对 ⇒ 空队列 + 可读 reason（绝不半崩）；
##   ② 入队 ⇒ 状态 = pending，提交号由**内容指纹**派生（同一关卡重复提交看得见、不覆盖别人）；
##   ③ 状态机 pending → reviewing → approved/rejected，每次流转追加历史、更新时间戳；
##   ④ 非法流转 / 未知状态 / 找不到 id ⇒ ok=false + 可读原因（不许静默改状态）；
##   ⑤ 原子写：调用方文档字典**只读**（不被改写），落盘后不留 `.tmp`；
##   ⑥ counts / status_text 与队列一致。
##
## 纪律：只在 `user://` 下的临时子目录建队列，绝不碰真实存档。

const SQ := preload("res://core/submission_queue.gd")
const TMP_DIR := "user://test_submission_queue"
const TMP := TMP_DIR + "/queue.json"


func before_each() -> void:
	_rmrf(TMP_DIR)


func after_each() -> void:
	_rmrf(TMP_DIR)


func _rmrf(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var p := path.path_join(n)
		if d.current_is_dir():
			_rmrf(p)
		else:
			DirAccess.remove_absolute(p)
		n = d.get_next()
	d.list_dir_end()
	# 连目录本身一起清掉：否则下一轮 make_dir_recursive_absolute 撞上「已存在」会报 engine error（测试被判红）。
	DirAccess.remove_absolute(path)


func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(TMP_DIR):
		DirAccess.make_dir_recursive_absolute(TMP_DIR)


func _level(name: String, mines: int = 3) -> Dictionary:
	var ms: Array = []
	for r in mines:
		ms.append({"c": r, "r": r})
	return {"name": name, "size": {"rows": 5, "cols": 5}, "mines": ms, "total_mines": mines}


# ==================== ① 空 / 坏档 ====================

func test_missing_file_is_empty_queue_not_error() -> void:
	var r := SQ.load_items(TMP)
	assert_true(bool(r["ok"]), "文件不存在应判为 ok（空队列不是错误）")
	assert_eq((r["items"] as Array).size(), 0, "空队列应没有条目")
	assert_eq(str(r.get("reason", "")), "", "空队列不该有 reason")


func test_corrupt_file_falls_back_to_empty_queue() -> void:
	_ensure_dir()
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string("{ 这不是 JSON ")
	f.close()
	var r := SQ.load_items(TMP)
	assert_true(bool(r["ok"]), "坏档应降级为空队列（不是崩溃）")
	assert_eq((r["items"] as Array).size(), 0, "坏档解出的队列应是空的")
	assert_true(str(r.get("reason", "")).length() > 0, "坏档必须给可读 reason")


func test_items_not_array_falls_back() -> void:
	_ensure_dir()
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string(JSON.stringify({"items": "不是数组"}))
	f.close()
	var r := SQ.load_items(TMP)
	assert_eq((r["items"] as Array).size(), 0, "items 不是数组时按空队列处理")
	assert_true(str(r.get("reason", "")).length() > 0, "结构不对必须给可读 reason")


# ==================== ② 入队 ====================

func test_submit_enqueues_pending_with_digest_id() -> void:
	var lv := _level("第一关")
	var r := SQ.submit(lv, "求审核", TMP)
	assert_true(bool(r["ok"]), "入队应成功：%s" % str(r.get("reason", "")))
	assert_eq(str(r["item"]["status"]), SQ.PENDING, "新提交状态应是 pending")
	assert_eq(int(r["count"]), 1, "队列应有 1 条")
	var id := str(r["id"])
	var digest := SQ.digest_of(lv)
	assert_true(id.begins_with("sub-"), "提交号应形如 sub-…")
	assert_true(id.find(digest.substr(0, 8)) != -1, "提交号应带内容指纹前缀（可辨认同一关卡）")
	# 落盘后可读回
	var loaded := SQ.load_items(TMP)
	assert_eq((loaded["items"] as Array).size(), 1, "落盘后应读回 1 条")
	assert_eq(str((loaded["items"] as Array)[0]["id"]), id, "读回的提交号应与写入一致")


func test_duplicate_submit_gets_unique_ids() -> void:
	var lv := _level("同一关")
	var a := SQ.submit(lv, "第一次", TMP)
	var b := SQ.submit(lv, "第二次", TMP)
	assert_true(bool(a["ok"]) and bool(b["ok"]), "两次都该成功")
	assert_ne(str(a["id"]), str(b["id"]), "同一关卡重复提交要拿到**不同**提交号（不互相覆盖）")
	assert_eq(int(b["count"]), 2, "重复提交后队列应有 2 条")


func test_level_dict_is_not_mutated() -> void:
	var lv := _level("只读")
	var before := JSON.stringify(lv)
	SQ.submit(lv, "别改我", TMP)
	assert_eq(JSON.stringify(lv), before, "submit 只读 level，不得改写调用方字典")


# ==================== ③ 合法流转 + 历史 ====================

func test_legal_transitions_append_history() -> void:
	var sub := SQ.submit(_level("流转"), "", TMP)
	var id := str(sub["id"])
	var r1 := SQ.advance(id, SQ.REVIEWING, TMP)
	assert_true(bool(r1["ok"]), "pending → reviewing 应合法：%s" % str(r1.get("reason", "")))
	assert_eq(str(r1["item"]["status"]), SQ.REVIEWING, "状态应变成 reviewing")
	var hist: Array = r1["item"]["history"]
	assert_eq(hist.size(), 2, "历史应追加到 2 条（pending + reviewing）")
	assert_eq(str(hist[1]["status"]), SQ.REVIEWING, "第二条历史是 reviewing")
	var r2 := SQ.advance(id, SQ.APPROVED, TMP, "符合规范")
	assert_true(bool(r2["ok"]), "reviewing → approved 应合法")
	assert_eq(str(r2["item"]["status"]), SQ.APPROVED, "状态应变成 approved")
	assert_eq(str((r2["item"]["history"] as Array)[2].get("reason", "")), "符合规范", "流转理由要落到历史里")
	# approved → reviewing（复核回炉）也合法
	var r3 := SQ.advance(id, SQ.REVIEWING, TMP)
	assert_true(bool(r3["ok"]), "approved → reviewing（复核）应合法")


func test_rejected_can_appeal_back_to_reviewing() -> void:
	var sub := SQ.submit(_level("申诉"), "", TMP)
	var id := str(sub["id"])
	assert_true(bool(SQ.advance(id, SQ.REJECTED, TMP, "命名不规范")["ok"]), "pending → rejected 应合法")
	var back := SQ.advance(id, SQ.REVIEWING, TMP, "已改名")
	assert_true(bool(back["ok"]), "rejected → reviewing（申诉）应合法")


# ==================== ④ 非法流转一律拒绝 ====================

func test_illegal_transition_rejected_with_reason() -> void:
	var sub := SQ.submit(_level("非法"), "", TMP)
	var id := str(sub["id"])
	# pending 不能直接跳到……它其实是允许 approved/rejected 的；用"同状态"和"未知状态"来测拒绝。
	var same := SQ.advance(id, SQ.PENDING, TMP)
	assert_false(bool(same["ok"]), "同状态流转应被拒绝")
	assert_true(str(same.get("reason", "")).find("已经") != -1, "同状态拒绝要给可读原因：%s" % str(same.get("reason", "")))
	# 造一个真实非法路径：reviewing → ？？？ reviewing 只允许 approved/rejected。
	assert_true(bool(SQ.advance(id, SQ.REVIEWING, TMP)["ok"]), "先进入 reviewing")
	var bad := SQ.advance(id, SQ.PENDING, TMP)
	assert_false(bool(bad["ok"]), "reviewing → pending 不在允许表里，必须拒绝")
	assert_true(str(bad.get("reason", "")).length() > 0, "非法流转要给可读原因")
	assert_eq(str(bad["item"]["status"]), SQ.REVIEWING, "被拒的流转不得改写状态")


func test_unknown_status_rejected() -> void:
	var sub := SQ.submit(_level("怪状态"), "", TMP)
	var r := SQ.advance(str(sub["id"]), "shipped", TMP)
	assert_false(bool(r["ok"]), "未知状态应被拒绝")
	assert_true(str(r.get("reason", "")).find("未知状态") != -1, "要说清是未知状态：%s" % str(r.get("reason", "")))


func test_advance_missing_id_rejected() -> void:
	var r := SQ.advance("sub-不存在", SQ.REVIEWING, TMP)
	assert_false(bool(r["ok"]), "找不到 id 应被拒绝")
	assert_true(str(r.get("reason", "")).find("没有提交号") != -1, "要说清找不到哪个提交号：%s" % str(r.get("reason", "")))


# ==================== ⑤ 原子写 ====================

func test_save_is_atomic_and_leaves_no_tmp() -> void:
	SQ.submit(_level("原子"), "", TMP)
	assert_false(FileAccess.file_exists(TMP + ".tmp"), "落盘后不得留 .tmp（原子替换应清干净）")
	assert_true(FileAccess.file_exists(TMP), "落盘后应有队列文件")


# ==================== ⑥ counts / status_text ====================

func test_counts_and_status_text_match_queue() -> void:
	var a := SQ.submit(_level("甲"), "", TMP)
	SQ.submit(_level("乙"), "", TMP)
	SQ.advance(str(a["id"]), SQ.APPROVED, TMP)
	var items: Array = SQ.load_items(TMP)["items"]
	var c := SQ.counts(items)
	assert_eq(int(c[SQ.PENDING]), 1, "应剩 1 条 pending")
	assert_eq(int(c[SQ.APPROVED]), 1, "应有 1 条 approved")
	var text := SQ.status_text(items)
	assert_true(text.find("共 2 条") != -1, "摘要要报总数：%s" % text)
	assert_true(text.find(SQ.label_of(SQ.APPROVED)) != -1, "摘要要出现状态标签：%s" % text)


func test_status_text_of_empty_queue_is_an_invitation() -> void:
	var text := SQ.status_text([])
	assert_true(text.find("加入审核队列") != -1, "空队列文案要指引下一步：%s" % text)


func test_describe_names_the_submission() -> void:
	var sub := SQ.submit(_level("描述关", 4), "", TMP)
	var d := SQ.describe(sub["item"])
	assert_true(d.find("描述关") != -1, "描述要带关卡名：%s" % d)
	assert_true(d.find("5×5") != -1, "描述要带尺寸：%s" % d)
	assert_true(d.find("4 雷") != -1, "描述要带雷数：%s" % d)