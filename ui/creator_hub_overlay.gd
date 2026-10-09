# creator_hub_overlay.gd —— 创作中心（**纯本地**闭环界面）
#
# 闭环四步（全部靠文件传递，零服务器 —— 用户口径：Steam 售卖、不租服务器）：
#   ① 登记版本：填作品名 + 变更说明（同一作品名再次登记 = 版本号 +1）；
#   ② 导出反馈包：把一条反馈写成 JSON 文件，发给测试者（也可以自己导出再回传，用于自测）；
#   ③ 导入反馈：读回反馈包，挂到对应版本上；
#   ④ 看数据：每条作品的版本数、平均评分、反馈原文。
#
# ⚠️ 刻意不写 class_name（坑表 #26）。入口：`CreatorHubOverlay.open(host)`。
extends RefCounted


const Shell := preload("res://ui/tool_shell.gd")
const Hub := preload("res://core/creator_hub.gd")
const AchService := preload("res://ui/achievement_service.gd")


static func open(host: Control) -> Control:
	var sh := Shell.build(host, "创作中心", _subtitle())
	if sh.is_empty():
		return null
	_fill(host, sh)
	return sh["root"] as Control


static func _subtitle() -> String:
	var s := Hub.stats()
	if int(s["packs"]) == 0:
		return "还没有登记过作品 —— 在编辑器里导出分享包，然后在这里登记一个版本"
	return "已登记 %d 个作品 / %d 个版本 / 收到 %d 条反馈（全部保存在本机 user://creator_hub.json）" % [
		int(s["packs"]), int(s["versions"]), int(s["feedback"])]


static func _fill(host: Control, sh: Dictionary) -> void:
	var body: VBoxContainer = sh["body"]
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	if sh.has("subtitle") and sh["subtitle"] != null:
		(sh["subtitle"] as Label).text = _subtitle()

	# ---- 顶部：登记新版本 ----
	body.add_child(Shell.section_header("登记新版本", "同一个作品名 = 更新（版本号 +1）", ""))
	var form := HBoxContainer.new()
	form.add_theme_constant_override("separation", 8)
	body.add_child(form)

	var title_le := LineEdit.new()
	title_le.name = "HubTitle"
	title_le.set_meta("hub_title", true)   # 测试 / 调试可据此定位
	title_le.placeholder_text = "作品名"
	title_le.custom_minimum_size = Vector2(260, 0)
	form.add_child(title_le)

	var notes_le := LineEdit.new()
	notes_le.name = "HubNotes"
	notes_le.set_meta("hub_notes", true)
	notes_le.placeholder_text = "本次变更说明（例如：调低第 3 关雷数）"
	notes_le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_child(notes_le)

	var add_btn := Button.new()
	add_btn.name = "HubPublish"
	add_btn.text = "登记"
	add_btn.focus_mode = Control.FOCUS_ALL
	add_btn.set_meta("hub_publish", true)
	UiTheme.style_button(add_btn)
	add_btn.pressed.connect(func():
		var t := title_le.text.strip_edges()
		if t == "":
			UiToast.popup(host, "先给作品起个名字", true)
			return
		var entry := Hub.publish(t, notes_le.text.strip_edges())
		AchService.refresh()   # 工艺组成就（发布 / 更新）当场亮
		UiToast.popup(host, "已登记「%s」v%d" % [str(entry["title"]), int(entry["version"])])
		notes_le.text = ""
		_fill(host, sh))
	form.add_child(add_btn)

	# ---- 作品列表 ----
	var packs := Hub.list_packs()
	if packs.is_empty():
		body.add_child(Shell.note("暂无可展示的作品。"))
		return

	for p in packs:
		var entry: Dictionary = p
		var pid := str(entry.get("id", ""))
		var fb := Hub.feedback_of(pid)
		var avg := Hub.average_rating(pid)
		body.add_child(Shell.section_header(
			"%s  v%d" % [str(entry.get("title", pid)), int(entry.get("version", 1))],
			str(entry.get("notes", "")),
			("平均 %.1f★ / %d 条反馈" % [avg, fb.size()]) if avg >= 0.0 else "%d 条反馈" % fb.size()))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.set_meta("hub_pack", pid)
		body.add_child(row)

		var exp_btn := Button.new()
		exp_btn.text = "导出反馈包"
		exp_btn.focus_mode = Control.FOCUS_ALL
		exp_btn.set_meta("hub_export", pid)
		UiTheme.style_button(exp_btn)
		exp_btn.pressed.connect(_export_feedback.bind(host, sh, pid, int(entry.get("version", 1))))
		row.add_child(exp_btn)

		var imp_btn := Button.new()
		imp_btn.text = "导入反馈"
		imp_btn.focus_mode = Control.FOCUS_ALL
		imp_btn.set_meta("hub_import", pid)
		UiTheme.style_button(imp_btn)
		imp_btn.pressed.connect(_import_feedback.bind(host, sh))
		row.add_child(imp_btn)

		var del_btn := Button.new()
		del_btn.text = "删除"
		del_btn.focus_mode = Control.FOCUS_ALL
		del_btn.set_meta("hub_delete", pid)
		UiTheme.style_button(del_btn)
		del_btn.pressed.connect(func():
			Hub.remove_pack(pid)
			UiToast.popup(host, "已删除「%s」" % str(entry.get("title", pid)))
			_fill(host, sh))
		row.add_child(del_btn)

		if fb.is_empty():
			body.add_child(Shell.note("  还没有反馈。"))
		else:
			for r in fb:
				var rec: Dictionary = r
				var stars := ""
				var n := clampi(int(rec.get("rating", 0)), 0, 5)
				for i in 5:
					stars += ("★" if i < n else "☆")
				body.add_child(Shell.note("  %s  %s  %s" % [
					stars, str(rec.get("tester", "匿名")), str(rec.get("comment", ""))]))

	body.add_child(Shell.note(
		"说明：反馈包是一个 JSON 文件（kind = tametsi_creator_feedback），可以通过任意渠道回传；\n"
		+ "本界面不上传、不联网、不统计订阅数 —— 全部数据都只在你自己的机器上。"))


static func _export_feedback(host: Control, sh: Dictionary, pid: String, version: int) -> void:
	var dlg := FileDialog.new()
	dlg.name = "HubExportDialog"
	dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.title = "导出反馈包（发给测试者，或自己留一份）"
	dlg.current_file = "%s_feedback.json" % pid
	dlg.size = Vector2i(720, 480)
	(sh["root"] as Control).add_child(dlg)
	dlg.file_selected.connect(func(path: String):
		var ok := Hub.export_feedback_pack(pid, "我自己", 0, "", path, version)
		UiToast.popup(host, "反馈包已导出" if ok else "导出失败", not ok))
	dlg.popup_centered()


static func _import_feedback(host: Control, sh: Dictionary) -> void:
	var dlg := FileDialog.new()
	dlg.name = "HubImportDialog"
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.title = "导入反馈包"
	dlg.filters = PackedStringArray(["*.json ; 反馈包"])
	dlg.size = Vector2i(720, 480)
	(sh["root"] as Control).add_child(dlg)
	dlg.file_selected.connect(func(path: String):
		var r := Hub.import_feedback(path)
		AchService.refresh()   # 工艺组成就（收到反馈）当场亮
		if bool(r["ok"]):
			var rec: Dictionary = r["entry"]
			UiToast.popup(host, "已导入 %s 的反馈" % str(rec.get("tester", "匿名")))
		else:
			UiToast.popup(host, _error_text(str(r["error"])), true)
		_fill(host, sh))
	dlg.popup_centered()


static func _error_text(code: String) -> String:
	match code:
		"missing": return "找不到这个文件"
		"bad_json": return "这个文件不是合法的 JSON"
		"bad_kind": return "这不是 Tametsi 反馈包"
		"bad_id": return "反馈包里没有作品 id"
		"unknown_pack": return "本地没有登记过这个作品"
	return "导入失败：" + code
