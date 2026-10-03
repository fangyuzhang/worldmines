# test_editor_repair_share.gd —— 修复建议「一键应用」+ 短码导出/导入**接进编辑器界面**的自证（2026-10-03）。
#
# 背景：审计核实 `core/repair_suggest.gd` / `core/share_code.gd` 早有实现与单测，但 `ui/` 零引用
# ⇒ 用户根本用不到。本文件钉住"真的接上了"：
#   · 修复建议：界面给出 1~3 条 + 一键应用，且应用**只算一步撤销**（撤一步要能完整退回）；
#   · 短码：能导出、能导入、非法码给可读报错且**不动文档、不抛异常**。
extends GutTest

## 与编辑器同法用 preload（坑 #26：这些新 core 类不在 headless 的全局类缓存里）。
const ShareCode = preload("res://core/share_code.gd")


func _make_editor() -> Object:
	var scene: PackedScene = load("res://ui/level_editor.tscn")
	assert_not_null(scene, "编辑器场景应能加载")
	var ed: Object = scene.instantiate()
	add_child_autofree(ed as Node)
	return ed


func _bind(ed: Object, d: EditorDoc) -> void:
	ed.doc = d
	ed.call("_doc_to_ui")
	ed.call("_refresh_all")


## 「需要猜测」的确定性小盘（与 test_repair_suggest.gd 同构）：1×4、雷 (0,0)(3,0)、只翻开 (1,0)。
func _guessy_doc() -> EditorDoc:
	var d := EditorDoc.new(1, 4)
	d.mines.append(Vector2i(0, 0))
	d.mines.append(Vector2i(3, 0))
	d.revealed[Vector2i(1, 0)] = null
	return d


func _find_button(ed: Object, prefix: String) -> Button:
	for c in (ed as Node).find_children("*", "Button", true, false):
		var b := c as Button
		if b != null and b.text.begins_with(prefix):
			return b
	return null


# ==================== 1. 修复建议：展示 + 一键应用 ====================

func test_repair_suggestions_are_shown_and_applying_is_one_undo_step() -> void:
	var ed := _make_editor()
	var d := _guessy_doc()
	_bind(ed, d)
	assert_eq(str(EditorVerify.verify_islands(d)["state"]), EditorVerify.STATE_NEEDS_GUESS,
		"前提：该盘应被判为需要猜测")

	await ed.call("_on_repair")          # 半公开入口：与按钮同一条路径（内部有 await 一帧）

	var box := ed.get("_repair_box") as VBoxContainer
	assert_not_null(box, "验证页应有修复建议列表")
	assert_gt(box.get_child_count(), 0, "需猜盘应至少给出 1 条建议行")
	assert_lte(box.get_child_count(), 3, "最多 3 条（需求写死 1~3）")
	var msg := (ed.get("_repair_msg") as Label).text
	assert_true(msg.length() > 0, "必须有可读说明（不许静默）：%s" % msg)
	assert_true(msg.find("应用") != -1, "说明要说清下一步怎么用：%s" % msg)

	# 每条建议行右边都要有可点的「应用」按钮
	var row := box.get_child(0) as HBoxContainer
	var apply_btn: Button = null
	for c in row.get_children():
		if c is Button:
			apply_btn = c
	assert_not_null(apply_btn, "每条建议都应有「应用」按钮")
	assert_eq(apply_btn.text, "应用", "按钮文案应是「应用」")

	var undo_before: int = (ed.get("_undo") as Array).size()
	apply_btn.pressed.emit()             # 真实入口：按按钮
	await wait_process_frames(2)         # `_apply_repair` 末尾会 await 重跑验证

	assert_eq(str(EditorVerify.verify_islands(d)["state"]), EditorVerify.STATE_NO_GUESS,
		"应用后应立即重跑校验并判为「不用猜」")
	assert_eq((ed.get("_undo") as Array).size(), undo_before + 1,
		"一键应用必须只算**一步**撤销（一次算一步，不污染重做链）")
	# 那一步撤销要能完整退回（否则"一步"是假的）
	ed.call("_undo_once")
	assert_eq(str(EditorVerify.verify_islands(d)["state"]), EditorVerify.STATE_NEEDS_GUESS,
		"撤一步应完整退回原盘")


func test_repair_on_a_solvable_board_says_no_repair_needed() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(3, 3)
	d.mines.append(Vector2i(2, 2))
	d.revealed[Vector2i(0, 0)] = null
	_bind(ed, d)
	await ed.call("_on_repair")
	var msg := (ed.get("_repair_msg") as Label).text
	assert_true(msg.find("不用修") != -1, "已可解的盘应直说不用修（不硬塞建议）：%s" % msg)
	assert_eq((ed.get("_repair_box") as VBoxContainer).get_child_count(), 0, "不该硬塞建议行")


func test_stale_repair_plan_leaves_no_undo_step_and_no_change() -> void:
	# 【这条钉的是原动机】UI 曾在落笔前自己抄一份判据，就为了"不适用时**别留下一步废撤销**"。
	# 判据收进 `RepairSuggest.can_apply()` 后，必须仍然如此：先问、再决定要不要 push。
	var ed := _make_editor()
	var d := _guessy_doc()
	_bind(ed, d)
	await ed.call("_on_repair")
	var plans := ed.get("_repair_plans") as Array
	assert_gt(plans.size(), 0, "前提：应拿到建议")
	var plan: Dictionary = plans[0]
	# 让这条建议"过期"：模拟用户在看建议时又改了盘（把它的目标格变成冲突）
	if str(plan.get("op", "")) == "add_clue":
		var c: Dictionary = plan["cell"]
		d.mines.append(Vector2i(int(c["c"]), int(c["r"])))
	else:
		var f: Dictionary = plan["from"]
		d.mines.erase(Vector2i(int(f["c"]), int(f["r"])))
	var undo_before: int = (ed.get("_undo") as Array).size()
	var snap := JSON.stringify(d.snapshot())
	# 真实入口：仍按那一行的「应用」按钮
	var row := (ed.get("_repair_box") as VBoxContainer).get_child(0) as HBoxContainer
	var btn: Button = null
	for ch in row.get_children():
		if ch is Button:
			btn = ch
	assert_not_null(btn, "建议行应有「应用」按钮")
	btn.pressed.emit()
	await wait_process_frames(2)
	assert_eq((ed.get("_undo") as Array).size(), undo_before,
		"不适用的修法**不许**留下撤销步（原来会先 push 再失败）")
	assert_eq(JSON.stringify(d.snapshot()), snap, "不适用的修法不许改动文档")
	var msg := (ed.get("_repair_msg") as Label).text
	assert_true(msg.length() > 0, "必须给出可读原因（不许静默）")
	assert_true(msg.find("不适用") != -1, "文案要说清是「这条修法现在不适用」：%s" % msg)


# ==================== 2. 短码：导出 / 导入 / 非法码可读报错 ====================

func test_share_code_round_trips_through_the_ui_buttons() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(5, 5)
	d.mines.append(Vector2i(0, 0))
	d.mines.append(Vector2i(4, 3))
	d.revealed[Vector2i(2, 2)] = null
	_bind(ed, d)

	var out_btn := _find_button(ed, "复制短码")
	assert_not_null(out_btn, "左栏应有「复制短码」按钮")
	out_btn.pressed.emit()
	var code := str((ed.get("_share_edit") as LineEdit).text)
	assert_true(code.length() > 0, "5×5 小关卡应能导出短码")
	assert_true(code.length() < 512, "小关卡的码不该长得像文件（实际 %d 字符）" % code.length())
	assert_true((ed.get("_share_note") as Label).text.length() > 0, "导出要有可读说明")

	# 换一个编辑器、换一份盘，用同一个短码载回来 ⇒ 必须完全还原
	var ed2 := _make_editor()
	_bind(ed2, EditorDoc.new(3, 3))
	(ed2.get("_share_edit") as LineEdit).text = code
	var in_btn := _find_button(ed2, "载入短码")
	assert_not_null(in_btn, "左栏应有「载入短码」按钮")
	in_btn.pressed.emit()
	assert_eq(ed2.doc.rows, 5, "行数应还原")
	assert_eq(ed2.doc.cols, 5, "列数应还原")
	assert_eq(ed2.doc.mine_count(), 2, "雷数应还原")
	assert_eq(str(ed2.doc.mines), str(d.mines), "雷位应还原")
	assert_eq(ed2.doc.revealed.size(), 1, "初始翻开格应还原")
	assert_true(ed2.doc.revealed.has(Vector2i(2, 2)), "翻开的那一格应还原")
	assert_true((ed2.get("_share_note") as Label).text.find("已载入") != -1,
		"导入成功也要有可读说明：%s" % (ed2.get("_share_note") as Label).text)


func test_illegal_share_code_is_reported_not_thrown() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(4, 4)
	d.mines.append(Vector2i(1, 1))
	_bind(ed, d)
	var before := JSON.stringify(d.snapshot())

	# ① 含非法字符
	(ed.get("_share_edit") as LineEdit).text = "这不是短码!!!"
	ed.call("_import_share_code")
	var note := (ed.get("_share_note") as Label).text
	assert_true(note.length() > 0, "非法码必须给可读报错（不许静默）")
	assert_true(note.find("非法字符") != -1, "报错要说清是哪一类问题：%s" % note)
	assert_eq(JSON.stringify(d.snapshot()), before, "非法码不得改动关卡")

	# ② 合法字符但被篡改 ⇒ 校验失败（同样可读、同样不动文档）
	var good := _encode_doc(d)
	assert_true(good.length() > 6, "前提：应能编出一条合法短码")
	var tampered := good.substr(0, 4) + ("A" if good[4] != "A" else "B") + good.substr(5)
	(ed.get("_share_edit") as LineEdit).text = tampered
	ed.call("_import_share_code")
	var note2 := (ed.get("_share_note") as Label).text
	assert_true(note2.length() > 0, "改过的码也要给可读报错")
	assert_true(note2.find("这不是一条能用的短码") != -1, "报错应被明确传出来：%s" % note2)
	assert_eq(JSON.stringify(d.snapshot()), before, "被篡改的码不得改动关卡")

	# ③ 空输入（无剪贴板内容时也只是提示，不崩、不改文档）
	(ed.get("_share_edit") as LineEdit).text = ""
	ed.call("_import_share_code")
	assert_true((ed.get("_share_note") as Label).text.length() > 0, "空输入也要有可读提示")
	assert_eq(JSON.stringify(d.snapshot()), before, "空输入不得改动关卡")


## 测试自用：拿编辑器用的同一个 core 编一条码（独立于 UI 的导出路径）。
func _encode_doc(d: EditorDoc) -> String:
	var r: Dictionary = ShareCode.encode(d.to_level_json())
	assert_true(bool(r["ok"]), "前提：该盘应能编成短码：%s" % str(r["reason"]))
	return str(r["code"])
