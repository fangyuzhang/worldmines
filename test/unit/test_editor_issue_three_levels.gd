# test_editor_issue_three_levels.gd —— 「本盘问题」**三级**显示的 UI 回归闸门
#
# 背景：`core/editor_doc.gd` 的 `validate()` 早已产出三级（❌error 阻止 / ⚠️warn 警告 / 💡info 提示），
# 且 `warnings` 桶是「warn ∪ info」的**兼容超集**；而 UI 原来只显两级（"错误 / 提醒"）⇒
# 提示级被混进"提醒"里、分级看不出来。本文件钉住修好之后的行为：
#   ④ 三级分别归类展示：三桶都有条目，且**分级正确**（不许全塞一桶）；
#   ⑤ 既有的「点条目跳转到该格」行为未被破坏（三级化只是分组，不是重写）。
#
# 类型纪律：编辑器脚本没有 `class_name` ⇒ 变量声明成 Object 并用 `.call()`。
extends GutTest


func _make_editor() -> Object:
	var scene: PackedScene = load("res://ui/level_editor.tscn")
	assert_not_null(scene, "编辑器场景应能加载")
	var ed: Object = scene.instantiate()
	add_child_autofree(ed as Node)
	await wait_process_frames(2)
	return ed


func _bind(ed: Object, d: EditorDoc) -> void:
	ed.doc = d
	ed.call("_doc_to_ui")
	ed.call("_refresh_all")


func _canvas_of(ed: Object) -> EditorCanvas:
	var found := (ed as Node).find_children("*", "EditorCanvas", true, false)
	return found[0] as EditorCanvas if not found.is_empty() else null


## 一份**同时含三级**问题的文档（每级各一条，来源可辨认）：
##   阻止：雷位越界 (20,20)
##   警告：单格邻接 35 格（>30，与 test_editor_issue_levels 同口径的构造）
##   提示：雷密度 >50%（41 颗实心交错 + 1 颗越界 = 42/81 ≈ 52%）
func _three_level_doc() -> EditorDoc:
	var d := EditorDoc.new(9, 9)
	var dirs: Array[Vector2i] = []
	for y in range(-3, 3):
		for x in range(-3, 3):
			if x != 0 or y != 0:
				dirs.append(Vector2i(x, y))
	d.dirs = dirs
	for y in range(9):
		for x in range(9):
			if (x + y) % 2 == 0:
				d.mines.append(Vector2i(x, y))
	d.mines.append(Vector2i(20, 20))     # 越界 ⇒ 阻止级
	return d


## 读 `_issues_box` 里的分组结构：{level: [条目节点…]}（标题节点本身不进去）。
## 判据是**元数据**（标题 `ed_issue_head` / 条目 `ed_issue_level`），不靠文案猜。
func _buckets_of(box: VBoxContainer) -> Dictionary:
	var out: Dictionary = {}
	for c in box.get_children():
		if c.has_meta("ed_issue_head"):
			var lv := str(c.get_meta("ed_issue_head"))
			if not out.has(lv):
				out[lv] = []
		elif c.has_meta("ed_issue_level"):
			var lv2 := str(c.get_meta("ed_issue_level"))
			if not out.has(lv2):
				out[lv2] = []
			(out[lv2] as Array).append(c)
	return out


func _bucket_text(buckets: Dictionary, level: String) -> String:
	var out := ""
	for c in (buckets.get(level, []) as Array):
		if c is Button:
			out += (c as Button).text + "\n"
		elif c is Label:
			out += (c as Label).text + "\n"
	return out


# ==================== ④ 三级分别归类展示，且分级正确 ====================

func test_three_levels_are_rendered_in_three_groups() -> void:
	var ed := await _make_editor()
	var d := _three_level_doc()
	# 前置：core 确实产出了三级（否则这条用例是空转）
	var rep := d.validate()
	assert_gt((rep["errors"] as Array).size(), 0, "前置：应有 error")
	assert_gt((rep["infos"] as Array).size(), 0, "前置：应有 info")
	_bind(ed, d)

	var box := ed.get("_issues_box") as VBoxContainer
	assert_not_null(box, "应有「本盘问题」清单")
	var buckets := _buckets_of(box)
	for lv in ["error", "warn", "info"]:
		assert_true(buckets.has(lv) and (buckets[lv] as Array).size() > 0,
			"三级各成一组且都有条目，缺 %s（实际分组：%s）" % [lv, str(buckets.keys())])
	# 分级正确：每一条都落在自己那一级（不许全塞一桶）
	assert_true(_bucket_text(buckets, "error").find("雷位越界") != -1,
		"「雷位越界」应在阻止级：%s" % _bucket_text(buckets, "error"))
	assert_true(_bucket_text(buckets, "warn").find("单格邻接") != -1,
		"「单格邻接过多」应在警告级：%s" % _bucket_text(buckets, "warn"))
	assert_true(_bucket_text(buckets, "info").find("雷密度") != -1,
		"「雷密度偏高」应在提示级：%s" % _bucket_text(buckets, "info"))
	# 反向：不许串桶
	assert_eq(_bucket_text(buckets, "warn").find("雷位越界"), -1, "阻止级的问题不许混进警告级")
	assert_eq(_bucket_text(buckets, "info").find("单格邻接"), -1, "警告级的问题不许混进提示级")
	# 每条条目的 level 元数据必须与所在分组一致
	for lv2 in buckets:
		for c in (buckets[lv2] as Array):
			assert_eq(str((c as Node).get_meta("ed_issue_level")), str(lv2),
				"条目的级别元数据必须与所在分组一致")


func test_group_headers_are_distinguishable_by_text_and_color() -> void:
	# 三级必须**可区分**：标题文案不同 + 颜色不同（颜色不能是唯一信号，所以两者都要）
	var ed := await _make_editor()
	_bind(ed, _three_level_doc())
	var box := ed.get("_issues_box") as VBoxContainer
	var titles: Dictionary = {}
	var colors: Dictionary = {}
	for c in box.get_children():
		if c.has_meta("ed_issue_head"):
			var lv := str(c.get_meta("ed_issue_head"))
			titles[lv] = (c as Label).text
			colors[lv] = (c as Label).get_theme_color("font_color")
	for lv2 in ["error", "warn", "info"]:
		assert_true(titles.has(lv2), "应有 %s 级的分组标题" % lv2)
	assert_true(str(titles["error"]) != str(titles["warn"]) and str(titles["warn"]) != str(titles["info"]),
		"三级标题文案必须互不相同：%s" % str(titles))
	assert_true(colors["error"] != colors["warn"] and colors["warn"] != colors["info"],
		"三级标题颜色必须互不相同：%s" % str(colors))
	assert_true(str(titles["error"]).find("阻止") != -1, "error 级文案应是「阻止」：%s" % str(titles["error"]))
	assert_true(str(titles["warn"]).find("警告") != -1, "warn 级文案应是「警告」：%s" % str(titles["warn"]))
	assert_true(str(titles["info"]).find("提示") != -1, "info 级文案应是「提示」：%s" % str(titles["info"]))


# ==================== ⑤ 点条目跳转到该格：未被三级化破坏 ====================

func test_clicking_an_issue_still_jumps_to_its_cell() -> void:
	var ed := await _make_editor()
	var canvas := _canvas_of(ed)
	canvas.size = Vector2(600, 600)
	_bind(ed, _three_level_doc())
	var box := ed.get("_issues_box") as VBoxContainer
	var jumpable: Array = []
	for c in box.get_children():
		if c is Button and c.has_meta("ed_jump_cell"):
			jumpable.append(c)
	assert_gt(jumpable.size(), 0, "带格坐标的问题（三级化之后）仍必须是可点条目")
	# 挑一条**盘内**的（越界雷位那条的坐标不在盘上，点了只能提示"不在盘上"，不适合验居中）
	var doc: Variant = ed.get("doc")
	var picked: Button = null
	for c in jumpable:
		var p: Vector2i = (c as Button).get_meta("ed_jump_cell")
		if bool(doc.grid().in_board(p)):
			picked = c as Button
			break
	assert_not_null(picked, "应有一条盘内问题可跳转：%s" % str(jumpable.size()))
	if picked == null:
		return
	var target: Vector2i = picked.get_meta("ed_jump_cell")
	picked.pressed.emit()
	var center := canvas.cell_rect(target).get_center()
	assert_almost_eq(center.x, canvas.size.x * 0.5, 1.0, "点条目后目标格应水平居中")
	assert_almost_eq(center.y, canvas.size.y * 0.5, 1.0, "点条目后目标格应垂直居中")
	assert_gte(canvas.zoom, 1.5, "跳转应抬高缩放，让目标格看得清")


func test_unknown_level_never_disappears_from_the_list() -> void:
	# 三级是 core 的枚举；将来 core 加一级 / 改取值而 UI 没同步时，**不许把这条静默丢掉**
	#（静默少一条问题比归错级严重得多）⇒ 兜底归到最重的「阻止」。
	var ed := await _make_editor()
	_bind(ed, EditorDoc.new(5, 5))
	ed.call("_refresh_issue_list", {"ok": false, "errors": [], "warnings": [], "infos": [],
		"issues": [{"code": "future", "text": "将来才有的第四级问题", "pos": Vector2i(-1, -1), "level": "fatal"}]})
	var box := ed.get("_issues_box") as VBoxContainer
	var text := ""
	for c in box.get_children():
		if c is Label:
			text += (c as Label).text + "\n"
	assert_true(text.find("将来才有的第四级问题") != -1,
		"认不出的级别必须兜底显示（不许静默丢）：%s" % text)
	assert_eq(str(box.get_child(0).get_meta("ed_issue_head")), "error", "兜底应归到最重的「阻止」级")


func test_empty_issue_set_still_says_there_is_no_problem() -> void:
	# 回归：三级化不许把"没有问题"这句话弄丢（空文档不能再冒出分组标题）
	var ed := await _make_editor()
	var d := EditorDoc.new(5, 5)
	d.mines.append(Vector2i(0, 0))
	_bind(ed, d)
	var box := ed.get("_issues_box") as VBoxContainer
	var text := ""
	for c in box.get_children():
		if c is Label:
			text += (c as Label).text
	assert_true(text.find("没有问题") != -1, "无问题时仍要说「没有问题」：%s" % text)
	assert_eq(_buckets_of(box).size(), 0, "无问题时不该有分组标题")
