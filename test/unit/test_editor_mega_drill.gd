# test_editor_mega_drill.gd —— 复合格（Mega Cell）**下钻 UI** 的回归闸门
#
# 背景：`core/mega_cell.gd` 的 `drill_state / drill_in / drill_out / drill_path / is_inside /
# drill_to_dict / drill_from_dict` 与规则（非法一律 ok=false 且 **state 逐字段不变**）早已单测；
# 本文件测的是**UI 入口**那一层（`ui/level_editor.gd` 的「复合格（下钻）」区）：
#   ① 走**真实入口**进入 / 返回复合格：路径与「是否在格内」随之变化，并在状态行里显示出来；
#   ② 非法目标（不存在的复合格 / 超深 / 顶层再退）必须显示 core 的 reason 原文，且状态不变；
#   ③ 下钻状态在 **UI 层**经 `drill_to_dict / drill_from_dict` 往返后逐字段一致（显示也跟着对上）。
#
# 类型纪律：编辑器脚本没有 `class_name` ⇒ 变量声明成 Object 并用 `.call()`；
# core 的 MegaCell 有 class_name（已在 .godot 类缓存里），但这里仍用 **preload** 引用静态方法，
# 与 `ui/level_editor.gd` 的接线方式保持一致（坑表 #26）。
extends GutTest

const MEGA := preload("res://core/mega_cell.gd")
const AUTOSAVE := "user://editor/_autosave.json"
const PLAY_FILE := "user://editor/_play.json"


func _read_file_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


## 退出用例时把用户存档原样放回（试玩路径会写这两个文件，不许污染别的套件）。
func _restore_file(path: String, text: String) -> void:
	if text == "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _make_editor() -> Object:
	var scene: PackedScene = load("res://ui/level_editor.tscn")
	assert_not_null(scene, "编辑器场景应能加载")
	var ed: Object = scene.instantiate()
	add_child_autofree(ed as Node)
	await wait_process_frames(2)   # 容器要两帧才排完版
	return ed


func _bind(ed: Object, d: EditorDoc) -> void:
	ed.doc = d
	ed.call("_doc_to_ui")
	ed.call("_refresh_all")


func _canvas_of(ed: Object) -> EditorCanvas:
	var found := (ed as Node).find_children("*", "EditorCanvas", true, false)
	return found[0] as EditorCanvas if not found.is_empty() else null


func _press(ed: Object, prefix: String) -> bool:
	for c in (ed as Node).find_children("*", "Button", true, false):
		var b := c as Button
		if b.get_class() == "Button" and b.text.begins_with(prefix):
			b.pressed.emit()
			return true
	return false


## 6x6 盘 + **两块**复合格（#1 三格、#2 两格）⇒ 下拉里有多个目标可切。
func _doc_with_mega() -> EditorDoc:
	var d := EditorDoc.new(6, 6)
	for m in [Vector2i(4, 4), Vector2i(5, 5)]:
		d.mines.append(m)
	var r1: Dictionary = d.mega_cells.merge([Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)])
	assert_true(bool(r1["ok"]), "前置：第一块复合格应能合并：%s" % str(r1))
	var r2: Dictionary = d.mega_cells.merge([Vector2i(3, 3), Vector2i(3, 4)])
	assert_true(bool(r2["ok"]), "前置：第二块复合格应能合并：%s" % str(r2))
	return d


## 在真实下拉里选到某个复合格 id（不绕过控件）。
func _select_mega(ed: Object, gid: int) -> bool:
	var opt := ed.get("_mega_opt") as OptionButton
	for i in opt.item_count:
		if int(opt.get_item_id(i)) == gid:
			opt.selected = i
			return true
	return false


# ==================== ① 真实入口：进入 / 返回，路径与"是否在格内"随之变化 ====================

func test_drill_in_and_out_through_the_real_ui_entries() -> void:
	var ed := await _make_editor()
	var d := _doc_with_mega()
	_bind(ed, d)
	var mega: Variant = d.mega_cells
	var ids: Array = mega.ids()
	assert_gt(ids.size(), 0, "文档里应有复合格（前置）")
	var gid: int = int(ids[0])
	# 真实入口的前提：下拉里列出的就是文档里的复合格
	var opt := ed.get("_mega_opt") as OptionButton
	assert_gt(opt.item_count, 0, "复合格应出现在下钻下拉里")
	assert_eq(int(opt.get_item_id(0)), gid, "下拉项 id 必须是复合格 id")
	var state := ed.get("_mega_state_label") as Label
	assert_not_null(state, "应有下钻状态行")
	# 初始：不在格内，状态行说"整盘视图"
	assert_false(bool(MEGA.is_inside(ed.get("_mega_drill"))), "初始不该在格内")
	assert_true(state.text.find("整盘视图") != -1, "初始状态行应说整盘视图：%s" % state.text)

	# 进入（点真实按钮）
	assert_true(_press(ed, "进入这一格"), "应有「进入这一格」按钮")
	assert_true(bool(MEGA.is_inside(ed.get("_mega_drill"))), "点进入后必须在格内")
	var path: Array[int] = MEGA.drill_path(ed.get("_mega_drill"))
	assert_eq(path.size(), 1, "深度上限 1 ⇒ 路径应为一段")
	assert_eq(path[0], gid, "层级路径应指向刚进入的复合格")
	assert_true(state.text.find("在复合格内部") != -1,
		"状态行必须显示「是否在格内」：%s" % state.text)
	assert_true(state.text.find("#%d" % gid) != -1,
		"状态行必须显示层级路径 #%d：%s" % [gid, state.text])
	# 下钻后高亮 = 该复合格的**内部基础格**（"看内部"要真的看得见）
	var canvas := _canvas_of(ed)
	var inner: Array = mega.internal_cells(gid)
	assert_eq(canvas.highlight.size(), inner.size(), "下钻后高亮应是内部基础格")
	for p in inner:
		assert_true(canvas.highlight.has(p), "内部格 %s 应在高亮里" % str(p))

	# 返回（点真实按钮）
	assert_true(_press(ed, "返回上一层"), "应有「返回上一层」按钮")
	assert_false(bool(MEGA.is_inside(ed.get("_mega_drill"))), "返回后必须回到顶层")
	assert_eq((MEGA.drill_path(ed.get("_mega_drill")) as Array).size(), 0, "返回后路径应为空")
	assert_true(state.text.find("整盘视图") != -1, "返回后状态行应回到整盘视图：%s" % state.text)
	# 退出后**视图回到整盘**：高亮交还给"问题格"口径（不再只剩那一片内部格）
	assert_eq(canvas.highlight.size(), d.highlight_cells(d.validate()).size(),
		"退出后高亮应回到整盘的问题格口径")


# ==================== ② 非法目标：显示 reason，且状态逐字段不变 ====================

func test_illegal_target_shows_reason_and_keeps_state_unchanged() -> void:
	var ed := await _make_editor()
	var d := _doc_with_mega()
	_bind(ed, d)
	var note := ed.get("_mega_note") as Label
	var state := ed.get("_mega_state_label") as Label
	assert_not_null(note, "应有下钻结果提示行")
	var top_before: Dictionary = (ed.get("_mega_drill") as Dictionary).duplicate(true)

	# ① 顶层再退：core 拒绝 ⇒ 必须把人话理由显示出来（不许静默）
	assert_true(_press(ed, "返回上一层"), "顶层也应有「返回上一层」（点了要给理由）")
	assert_true(note.text.find("已在顶层") != -1,
		"顶层再退必须显示 core 的理由原文：%s" % note.text)
	assert_eq(ed.get("_mega_drill"), top_before, "失败后下钻状态必须逐字段不变")
	assert_true(state.text.find("整盘视图") != -1, "失败后仍应显示整盘视图：%s" % state.text)

	# ② 目标不存在：下拉里塞一个已失效 id，走同一条真实入口
	var opt := ed.get("_mega_opt") as OptionButton
	opt.add_item("复合格 #9999（已不存在）", 9999)
	opt.selected = opt.item_count - 1
	assert_true(_press(ed, "进入这一格"), "点进入")
	assert_true(note.text.find("不存在") != -1,
		"非法目标必须显示 core 的理由（含「不存在」）：%s" % note.text)
	assert_eq(ed.get("_mega_drill"), top_before, "非法目标失败后状态必须逐字段不变")

	# ③ 超深：先合法进入一格，再进第二层（core 上限 1 层）⇒ 显示 depth 理由 + 状态不变
	var gid: int = int((d.mega_cells.ids() as Array)[0])
	assert_true(_select_mega(ed, gid), "应能在下拉里选到复合格 #%d" % gid)
	assert_true(_press(ed, "进入这一格"), "先进入一个合法复合格")
	var inside: Dictionary = (ed.get("_mega_drill") as Dictionary).duplicate(true)
	assert_true(bool(MEGA.is_inside(inside)), "前置：此时应在格内")
	assert_true(_press(ed, "进入这一格"), "已在一格内部时再点进入")
	assert_true(note.text.find("深度上限") != -1,
		"超深必须显示 core 的理由原文：%s" % note.text)
	assert_eq(ed.get("_mega_drill"), inside, "超深被拒后状态必须逐字段不变")
	assert_eq(MEGA.drill_path(ed.get("_mega_drill")), MEGA.drill_path(inside), "路径必须原样")


# ==================== ③ UI 层往返：drill_to_dict / drill_from_dict 一致 ====================

func test_drill_state_round_trips_through_the_ui_layer() -> void:
	var ed := await _make_editor()
	var d := _doc_with_mega()
	_bind(ed, d)
	var gid: int = int((d.mega_cells.ids() as Array)[0])
	assert_true(_select_mega(ed, gid), "选中复合格")
	assert_true(_press(ed, "进入这一格"), "先进入复合格")
	assert_true(bool(MEGA.is_inside(ed.get("_mega_drill"))), "前置：应在格内")
	var inside_path: Array[int] = MEGA.drill_path(ed.get("_mega_drill"))

	# UI 的序列化入口必须就是 core 的口径（UI 不许自造格式）
	var snap: Dictionary = ed.call("_mega_drill_snapshot")
	assert_eq(snap, MEGA.drill_to_dict(ed.get("_mega_drill")), "UI 快照必须等于 core 的 to_dict 产物")

	# 打回顶层，再用 UI 的还原入口读回来
	assert_true(_press(ed, "返回上一层"), "回到顶层")
	assert_false(bool(MEGA.is_inside(ed.get("_mega_drill"))), "已回到顶层")
	var back := bool(ed.call("_mega_drill_restore", snap))
	assert_true(back, "还原后应在格内")
	assert_eq(MEGA.drill_path(ed.get("_mega_drill")), inside_path, "往返后路径必须逐字段一致")
	# 显示层也要跟着对上（往返不许只改数据、界面还说"整盘视图"）
	var state := ed.get("_mega_state_label") as Label
	assert_true(state.text.find("#%d" % gid) != -1,
		"还原后状态行必须显示同一路径：%s" % state.text)
	# 空状态也要能往返（顶层 ⇒ 顶层）
	assert_false(bool(ed.call("_mega_drill_restore", MEGA.drill_to_dict(MEGA.drill_state()))),
		"空状态还原后应仍在顶层")
	assert_true(state.text.find("整盘视图") != -1, "空状态还原后状态行应说整盘视图")


# ==================== ④ 真实视图切换（试玩往返）里的下钻状态往返 ====================

func test_drill_view_survives_the_playtest_round_trip() -> void:
	# 试玩显示的是**整盘**（游戏里没有下钻这回事）⇒ 进试玩先退回顶层、回编辑再还原；
	# 还原走 UI 的 `_mega_drill_restore`（= core 的 `drill_from_dict`），不是另存一份内存副本。
	var backup_save := _read_file_text(AUTOSAVE)
	var backup_play := _read_file_text(PLAY_FILE)
	var ed := await _make_editor()
	var d := _doc_with_mega()
	_bind(ed, d)
	var gid: int = int((d.mega_cells.ids() as Array)[0])
	assert_true(_select_mega(ed, gid), "选中复合格")
	assert_true(_press(ed, "进入这一格"), "先进入复合格")
	assert_true(bool(MEGA.is_inside(ed.get("_mega_drill"))), "前置：应在格内")
	ed.call("_toggle_playtest")                 # Tab：进试玩
	await wait_process_frames(2)
	assert_not_null(ed.get("_play_overlay"), "应进入内嵌试玩态")
	assert_false(bool(MEGA.is_inside(ed.get("_mega_drill"))), "试玩态显示整盘 ⇒ 不该还停在「在格内」")
	ed.call("_toggle_playtest")                 # Tab：回编辑
	await wait_process_frames(2)
	assert_null(ed.get("_play_overlay"), "应回到编辑态")
	assert_true(bool(MEGA.is_inside(ed.get("_mega_drill"))), "回编辑后下钻视图应被还原")
	var expect: Array[int] = [gid]
	assert_eq(MEGA.drill_path(ed.get("_mega_drill")), expect, "还原的路径必须与进试玩前一致")
	var state := ed.get("_mega_state_label") as Label
	assert_true(state.text.find("#%d" % gid) != -1, "状态行也要跟着还原：%s" % state.text)
	_restore_file(AUTOSAVE, backup_save)
	_restore_file(PLAY_FILE, backup_play)
