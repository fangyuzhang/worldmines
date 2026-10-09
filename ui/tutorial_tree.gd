# tutorial_tree.gd —— 教学树（按算子轴分章、软解锁、可逐页打开）
#
# 与旧的「某变体的教程」入口的关系：那个入口是**上下文相关**的（在哪个变体就看哪一页），
# 本面板是**全局课程表**（第 1 章 → 第 6 章按顺序铺开）。两者共用同一个 TutorialOverlay 阅读器。
#
# 软解锁：进入下一章只要求「上一章看过 ≥1 页」，锁住的章**不是隐藏**而是显示成灰条 +
# 一句「读完上一章任意一页即解锁」——隐藏会让玩家以为内容不存在。
#
# 进度落 core/tutorial_progress.gd（user://tutorial_seen.json），与关卡通关进度分开存。
#
# ⚠️ 刻意不写 class_name（坑表 #26）。入口：`TutorialTree.open(host)`。
extends RefCounted


const Shell := preload("res://ui/tool_shell.gd")
const TutTree := preload("res://core/tutorial_catalog.gd")
const TProg := preload("res://core/tutorial_progress.gd")
const OverlayScript := "res://ui/tutorial_overlay.gd"
const AchService := preload("res://ui/achievement_service.gd")


static func open(host: Control) -> Control:
	var sh := Shell.build(host, "教学树", _subtitle())
	if sh.is_empty():
		return null
	_fill(host, sh)
	return sh["root"] as Control


static func _subtitle() -> String:
	var p := TutTree.progress(TProg.seen())
	var next := TutTree.next_page(TProg.seen())
	if next == "":
		return "已读 %d / %d —— 全部读完了，随时可以回来复习" % [int(p["seen"]), int(p["total"])]
	return "已读 %d / %d —— 下一课：%s" % [int(p["seen"]), int(p["total"]), next]


## 重建内容（标记已读后调用；不重建整层，避免把阅读器顶掉）。
static func _fill(host: Control, sh: Dictionary) -> void:
	var body: VBoxContainer = sh["body"]
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	if sh.has("subtitle") and sh["subtitle"] != null:
		(sh["subtitle"] as Label).text = _subtitle()

	var seen := TProg.seen()
	for ch in TutTree.chapters():
		var cid := str(ch["id"])
		var prog := TutTree.chapter_progress(cid, seen)
		var unlocked := TutTree.is_chapter_unlocked(cid, seen)
		body.add_child(Shell.section_header(
			("◆ " if unlocked else "◇ ") + str(ch["name"]),
			str(ch["desc"]),
			"已读 %d / %d" % [int(prog["seen"]), int(prog["total"])]))

		var box := VBoxContainer.new()
		box.name = "Chapter_" + cid
		box.add_theme_constant_override("separation", 4)
		box.set_meta("tut_chapter", cid)
		box.set_meta("tut_unlocked", unlocked)
		body.add_child(box)

		if not unlocked:
			var locked := Shell.note("读完上一章的任意一页即可解锁本章。")
			locked.set_meta("tut_locked_note", true)
			box.add_child(locked)
			continue

		for pid in (ch["pages"] as Array):
			var page_id := str(pid)
			var sub := TutTree.subtitle_of(page_id)
			var btn := Button.new()
			btn.text = ("✔ " if TProg.is_seen(page_id) else "○ ") + page_id + ("" if sub == "" else "  ·  " + sub)
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			btn.focus_mode = Control.FOCUS_ALL
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.set_meta("tut_page", page_id)
			UiTheme.style_button(btn)
			btn.pressed.connect(_open_page.bind(host, page_id, sh))
			box.add_child(btn)


## 打开某一页（复用对局 / 弹窗里同一个阅读器），关闭后刷新本面板的已读标记。
static func _open_page(host: Control, page_id: String, sh: Dictionary) -> void:
	if host == null or not is_instance_valid(host):
		return
	TProg.mark_seen(page_id)
	# 教学类成就不该等到下一局通关才亮（读了 30 页却毫无反馈 = 读成"成就坏了"）。
	AchService.refresh()
	var ov: Control = load(OverlayScript).new()
	host.add_child(ov)
	ov.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ov.call("open", [page_id], true)
	# 阅读器读同一页即算已读；关闭（离开场景树）后刷新勾选状态。
	ov.tree_exited.connect(func():
		if is_instance_valid(host) and sh.has("body"):
			_fill(host, sh))
