# test_level_editor_smoke.gd —— 编辑器 UI（P2）冒烟：场景能装载、面板建起来、能绑文档、坐标对得上
#
# 为什么放 test/unit 而不是 test/ui：本仓 CI 只跑 `-gdir=res://test/unit`
#（`tools/ci_check.ps1:45`）⇒ 放 test/ui 的测试**根本不会被执行**。
#
# 这里不测像素，只测"结构性正确"（节点在、面板数量对、坐标换算自洽、格型互斥成立）：
# 无头环境不渲染，画得对不对没法用断言表达（那要靠人眼看 + 真机冒烟）。
#
# 类型纪律：编辑器脚本没有 `class_name`，所以变量一律声明成 `Object` 并用 `.call()`
# 调它的方法——若声明成 `Control` 再调自定义方法，GDScript 静态检查会直接编译失败。
extends GutTest


func _make_editor() -> Object:
	var scene: PackedScene = load("res://ui/level_editor.tscn")
	assert_not_null(scene, "编辑器场景应能加载（.tscn 头与脚本路径必须正确）")
	var ed: Object = scene.instantiate()
	add_child_autofree(ed as Node)   # 加进树才会跑 _ready（面板都在 _ready 里建）
	return ed


func _canvas_of(ed: Object) -> EditorCanvas:
	var n := ed as Node
	var found := n.find_children("*", "EditorCanvas", true, false)
	if found.is_empty():
		return null
	return found[0] as EditorCanvas


func _doc5() -> EditorDoc:
	var d := EditorDoc.new(5, 5)
	for m in [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)]:
		d.mines.append(m)
	d.revealed[Vector2i(4, 4)] = null
	return d


func _bind(ed: Object, d: EditorDoc) -> void:
	ed.doc = d
	ed.call("_doc_to_ui")
	ed.call("_refresh_all")


func test_scene_builds_canvas_and_three_panels() -> void:
	var ed := _make_editor()
	assert_not_null(ed.doc, "编辑器应带一份初始文档")
	assert_not_null(_canvas_of(ed), "应有画布节点（EditorCanvas）")
	var tabs := (ed as Node).find_children("*", "TabContainer", true, false)
	assert_eq(tabs.size(), 1, "右侧应是唯一一个 TabContainer")
	if tabs.size() == 1:
		assert_eq((tabs[0] as TabContainer).get_tab_count(), 4, "应有属性 / AI 帮我写 / 规则 / 验证 四页")
	var panels := (ed as Node).find_children("*", "PanelContainer", true, false)
	assert_true(panels.size() >= 1, "应有底部状态栏")
	# 属性页的关键控件都在（形状下拉是"从零画六边形/三角/圆/星/扇"的入口）
	assert_not_null(ed.get("_shape_opt"), "应有形状下拉")
	assert_not_null(ed.get("_shape_size"), "应有形状尺寸控件")
	assert_not_null(ed.get("_issues_box"), "应有「本盘问题」清单")
	# 2026-10-03：形状下拉从 3 项扩到 6 项（新增圆 / 星 / 扇——参数化轮廓族）。
	# 2026-10-09：再扩到 7 项（新增 Voronoi 不规则镶嵌——种子驱动的自定义格形，core/shape_generator.gd 的 (p) 段）。
	assert_eq((ed.get("_shape_opt") as OptionButton).item_count, 7,
			"形状下拉应有 方阵/六边形/三角/圆/星/扇/Voronoi 七项")
	# 零代码页（AI 帮我写）：小白路径的每个环节都要在，坏一环就等于这条路径断了
	assert_not_null(ed.get("_idea_edit"), "应有「想法」输入框")
	assert_not_null(ed.get("_ai_text"), "应有粘贴 AI 回复的框")
	assert_not_null(ed.get("_ai_result"), "应有结果说明区")
	assert_not_null(ed.get("_ai_fix_btn"), "应有「让 AI 修」按钮")
	assert_not_null(ed.get("_recipe_opt"), "应有现成配方下拉")
	assert_true((ed.get("_recipe_opt") as OptionButton).item_count > 3, "配方下拉应有若干条现成规则")
	assert_true((ed.get("_ai_fix_btn") as Button).disabled, "还没失败时「让 AI 修」应禁用（避免误点）")


func test_editor_binds_doc_and_feeds_preview_into_canvas() -> void:
	var ed := _make_editor()
	_bind(ed, _doc5())
	var canvas := _canvas_of(ed)
	assert_not_null(canvas.doc, "画布应绑定文档")
	assert_eq(canvas.values.size(), 22, "5x5 减 3 颗雷 = 22 个非雷格应有预览值")
	assert_true(canvas.values.has(Vector2i(4, 4)), "被翻开的格也应有值")


func test_canvas_coordinate_mapping_round_trips() -> void:
	var ed := _make_editor()
	_bind(ed, _doc5())
	var canvas := _canvas_of(ed)
	canvas.size = Vector2(600, 600)
	for p in [Vector2i(0, 0), Vector2i(2, 2), Vector2i(4, 4)]:
		assert_eq(canvas.pos_at(canvas.cell_rect(p).get_center()), p,
			"格心应映射回同一格：%s" % str(p))
	assert_eq(canvas.pos_at(Vector2(-8, -8)), Vector2i(-1, -1), "盘外应返回 (-1,-1)")


func test_editor_kind_helpers_keep_cell_kinds_mutually_exclusive() -> void:
	var ed := _make_editor()
	var d := _doc5()
	ed.doc = d
	var p := Vector2i(3, 3)
	ed.call("_apply_kind_at", p, EditorCanvas.KIND_MINE)
	assert_true(d.mines.has(p), "应写入雷")
	ed.call("_apply_kind_at", p, EditorCanvas.KIND_OBSTACLE)
	assert_false(d.mines.has(p), "改成障碍后不应还留着雷（互斥）")
	assert_true(d.obstacles.has(p), "应写入障碍")
	ed.call("_apply_kind_at", p, EditorCanvas.KIND_CLEAR)
	assert_false(d.obstacles.has(p), "清空后应什么都不剩")
	assert_eq(str(ed.call("_kind_of", p)), EditorCanvas.KIND_CLEAR, "kind_of 应报「清空」")


func test_editor_validates_and_verifies_through_the_panels() -> void:
	var ed := _make_editor()
	var d := _doc5()
	_bind(ed, d)
	assert_true(bool(d.validate()["ok"]), "这份 5x5 文档应通过校验")
	# `_on_verify` 现在是**协程**：先刷"正在验证…"并等一帧（让用户真看到），再算。
	# 所以这里必须 await 到它跑完，否则断言会赶在结论写出来之前执行。
	await ed.call("_on_verify")
	var state_label := ed.get("_verify_state") as Label
	assert_not_null(state_label, "验证面板应有结论标签")
	assert_true(state_label.text.length() > 0, "验证面板应显示结论：%s" % state_label.text)
	var issues := ed.get("_verify_issues") as VBoxContainer
	assert_true(issues.get_child_count() > 0, "验证面板应显示统计/问题")


func test_editor_scene_is_not_excluded_from_exports() -> void:
	# 打包面守卫（P4）：编辑器是**运行时资源**（玩家从选关页进），必须随包发布。
	# 只查 exclude_filter 那一行里有没有点名编辑器——不用"ui/ 是否出现"这种宽判据，
	# 否则将来有人合理地排除 ui/ 的某个子目录时会假红。
	var cfg := FileAccess.get_file_as_string("res://export_presets.cfg")
	assert_true(cfg.find("exclude_filter=") != -1, "预设应含 exclude_filter")
	var ex_line := ""
	for line in cfg.split("\n"):
		if line.begins_with("exclude_filter="):
			ex_line = line
			break
	assert_false(ex_line.find("level_editor") != -1, "编辑器不得被 exclude_filter 排除：%s" % ex_line)
	assert_false(ex_line.find("editor_canvas") != -1, "编辑器画布不得被排除：%s" % ex_line)
	assert_false(ex_line.find("ui/*") != -1, "不得整体排除 ui/（玩家侧还有选关页等）：%s" % ex_line)


func test_right_click_erases_a_cell_and_can_drag() -> void:
	# 【用户需求 2026-10-02】右键 = 橡皮：单击擦该格、按住拖动连擦；**不改当前工具**。
	# 走真实输入路径（构造鼠标事件喂画布），因为要验的正是"按钮派发到哪条分支"。
	var ed := _make_editor()
	var d := _doc5()                     # 已有雷 (0,0)(1,1)(2,2) + 已翻开 (4,4)
	_bind(ed, d)
	var canvas := _canvas_of(ed)
	canvas.size = Vector2(600, 600)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_RIGHT
	down.pressed = true
	down.position = canvas.cell_rect(Vector2i(1, 1)).get_center()
	canvas._gui_input(down)
	assert_false(d.mines.has(Vector2i(1, 1)), "右键应擦掉该格的雷（改动前：右键什么都不做）")
	var mv := InputEventMouseMotion.new()
	mv.position = canvas.cell_rect(Vector2i(2, 2)).get_center()
	mv.button_mask = MOUSE_BUTTON_MASK_RIGHT
	canvas._gui_input(mv)
	assert_false(d.mines.has(Vector2i(2, 2)), "按住右键拖动应连续擦掉经过的格子")
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_RIGHT
	up.pressed = false
	up.position = canvas.cell_rect(Vector2i(0, 0)).get_center()
	canvas._gui_input(up)
	assert_true(d.mines.has(Vector2i(0, 0)), "松开右键后不得再擦（这一格必须还在）")
	assert_eq(canvas.tool, EditorCanvas.Tool.PAINT, "右键擦除不得改动当前工具（擦完要能接着画）")


func test_rect_fill_paints_the_whole_dragged_box() -> void:
	# P2 E2E：矩形填充（此前全仓测试零命中）。走**真实输入路径**：按下 → 拖动 → 抬起。
	var ed := _make_editor()
	var d := _doc5()
	_bind(ed, d)
	var canvas := _canvas_of(ed)
	canvas.size = Vector2(600, 600)
	canvas.tool = EditorCanvas.Tool.RECT_FILL
	var a := Vector2i(0, 4)
	var b := Vector2i(2, 4)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = canvas.cell_rect(a).get_center()
	canvas._gui_input(down)
	var mv := InputEventMouseMotion.new()
	mv.position = canvas.cell_rect(b).get_center()
	mv.button_mask = MOUSE_BUTTON_MASK_LEFT
	canvas._gui_input(mv)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = canvas.cell_rect(b).get_center()
	canvas._gui_input(up)
	for p in [Vector2i(0, 4), Vector2i(1, 4), Vector2i(2, 4)]:
		assert_true(d.mines.has(p), "矩形填充应把整框刷成当前格型（缺 %s）：%s" % [str(p), str(d.mines)])


func test_undo_steps_back_through_the_real_input_path() -> void:
	# 撤销点必须取在"改动之前"。这条走**真实输入路径**（构造鼠标事件喂给画布），
	# 因为该缺陷正是"信号时序"问题：若快照存的是改动**之后**的状态，
	# 按一次撤销等于没动（2026-10-02 复查发现并修掉）。
	var ed := _make_editor()
	var d := _doc5()
	_bind(ed, d)
	var canvas := _canvas_of(ed)
	canvas.size = Vector2(600, 600)
	var target := Vector2i(3, 3)
	var before := d.mines.size()

	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = canvas.cell_rect(target).get_center()
	canvas._gui_input(ev)
	assert_eq(d.mines.size(), before + 1, "画笔应写入一格雷（默认工具=画笔、格型=地雷）")

	ed.call("_undo_once")
	assert_eq(d.mines.size(), before, "撤销必须回到**改动前**的状态（不是回到改动后）")
	assert_false(d.mines.has(target), "该格应恢复为无雷")


func test_editor_is_wired_into_level_select() -> void:
	# 反向守卫：入口被删掉的话，玩家就再也进不去编辑器了
	var src := FileAccess.get_file_as_string("res://ui/level_select.gd")
	assert_true(src.find("res://ui/level_editor.tscn") != -1, "选关页应有编辑器入口")


# ==================== 零代码路径（AI 帮我写） ====================
#
# 这两条走**真实入口**（把文本放进 _ai_text，再调 _import_ai_text）：小白路径的关键
# 恰恰在"粘回来那一步"——解析、分流、注册、重算，缺一环他都得不到结果。

var _registered: Array[String] = []


func after_each() -> void:
	# 注册表是进程级单例、且没有 clear()：导入成功会留下规则，必须清理（否则污染别的套件）。
	for rid in _registered:
		RuleRegistry.default().unregister(StringName(rid))
	_registered.clear()


## 一条「周围 8 格」的规格（AI 回复里最常见的那种）。
func _r8_spec(id: String) -> Dictionary:
	var refs: Array = []
	var xs: Array = []
	var dirs: Array[Vector2i] = ClueEngine.ring_dirs()
	for i in dirs.size():
		refs.append({"dx": dirs[i].x, "dy": dirs[i].y})
		xs.append({"t": "ref", "i": i})
	return {"spec_version": 1, "id": id, "title": "测试用周围 8 格", "geometry": "rect_only",
		"clue": {"refs": refs, "expr": {"t": "sum", "xs": xs}, "max": 8}}


func test_ai_tab_understands_a_pasted_reply_and_applies_it() -> void:
	var ed := _make_editor()
	var d := _doc5()
	_bind(ed, d)
	# 真实形态：AI 的回复带解释文字 + ```json 围栏（不是干净的 JSON）
	(ed.get("_ai_text") as TextEdit).text = \
		"好的，这是你要的规则：\n```json\n%s\n```\n它把数字算成周围 8 格的雷数。" % JSON.stringify(_r8_spec("spec_ai_test_r8"))
	ed.call("_import_ai_text")
	if RuleRegistry.default().resolve(StringName("spec_ai_test_r8")) != null:
		_registered.append("spec_ai_test_r8")

	assert_not_null(RuleRegistry.default().resolve(StringName("spec_ai_test_r8")),
		"AI 给的规格必须被注册（否则「试玩 / 生成」用不了它）")
	assert_eq(str(d.rule_spec.get("id", "")), "spec_ai_test_r8", "规格必须写进文档（唯一真源）")
	assert_true(str((ed.get("_spec_edit") as TextEdit).text).find("spec_ai_test_r8") != -1,
		"「规则」页必须看到同一份规格（两页共用一个真源，不能各存一份）")
	var out := ed.get("_ai_result") as Label
	assert_true(out.text.find("导入成功") != -1, "结果区必须告诉小白成功了：%s" % out.text)
	assert_true(out.text.find("下一步") != -1, "要说清下一步做什么：%s" % out.text)
	assert_true((ed.get("_ai_fix_btn") as Button).disabled, "成功后应禁用「让 AI 修」")
	# 数字必须**立刻**按新规则重算出来：(2,0) 的邻居里有 (1,1) 一颗雷 ⇒ 1
	var canvas := _canvas_of(ed)
	assert_eq(int(canvas.values.get(Vector2i(2, 0), -1)), 1, "导入后棋盘数字必须立刻按新规则重算")


func test_ai_tab_offers_a_repair_round_when_the_reply_is_broken() -> void:
	# 失败的规格绝不能写进文档；且必须给小白一条**他能执行**的出路（交给 AI 修）。
	var ed := _make_editor()
	var d := _doc5()
	_bind(ed, d)
	var spec := _r8_spec("spec_ai_broken")
	spec.erase("title")   # 故意缺 title（AI 常犯）
	(ed.get("_ai_text") as TextEdit).text = "```json\n%s\n```" % JSON.stringify(spec)
	ed.call("_import_ai_text")
	var out := ed.get("_ai_result") as Label
	assert_true(out.text.find("还差一点") != -1, "必须给小白能懂的失败说明：%s" % out.text)
	assert_false((ed.get("_ai_fix_btn") as Button).disabled, "失败后「让 AI 修」必须可用")
	assert_eq(str(d.rule_spec.get("id", "")), "", "失败的规格不得写进文档")
	assert_null(RuleRegistry.default().resolve(StringName("spec_ai_broken")), "失败的规格不得注册")
	var errs := ed.get("_ai_last_errors") as Array
	assert_gt(errs.size(), 0, "失败时必须记住报错（「让 AI 修」要用它）")

# ==================== 存档占用锁 + 缩略图（文档 §8「防事故」） ====================
#
# 这两条钉的是**接线**（算法本身另有 test_file_lock / test_level_thumbnail 单测）：
#   · 保存要顺手写一份缩略图 sidecar；
#   · sidecar **不是关卡**，不得出现在「打开这个存档」里（选中它会加载成一份假关卡）；
#   · 别人正开着同一份存档时，第二会话必须**只读**打开，且保存不得覆盖它。
# 本套件因此会碰 user:// ⇒ 被 tools/gut_shards.ps1 自动收进"有状态"串行片（不会与并行片抢盘）。

const EDITOR_DIR := "user://editor"
## 固定且独特的标题：存到固定文件名，既不与真人存档重名，也便于本用例收尾。
const SMOKE_TITLE := "zz_smoke_lock_thumb"


func _open_items(ed: Object) -> Array[String]:
	var out: Array[String] = []
	var opt := ed.get("_open_opt") as OptionButton
	if opt == null:
		return out
	for i in opt.item_count:
		out.append(opt.get_item_text(i))
	return out


func _cleanup_save(path: String) -> void:
	if path == "":
		return
	DirAccess.remove_absolute("%s/%s.thumb.json" % [path.get_base_dir(), path.get_file()])
	DirAccess.remove_absolute(path)
	var lock_dir := "%s/.%s.lock" % [path.get_base_dir(), path.get_file()]
	DirAccess.remove_absolute(lock_dir.path_join(".level.lock"))
	DirAccess.remove_absolute(lock_dir)


func test_save_writes_thumb_sidecar_and_the_open_list_hides_it() -> void:
	var ed := _make_editor()
	var d := _doc5()
	d.title = SMOKE_TITLE
	_bind(ed, d)
	ed.call("_save")
	var path := str(ed.get("_current_path"))
	assert_eq(path, "%s/%s.json" % [EDITOR_DIR, SMOKE_TITLE], "保存路径应由标题决定（本用例据此收尾）")
	var sidecar := "%s/%s.thumb.json" % [path.get_base_dir(), path.get_file()]
	assert_true(FileAccess.file_exists(sidecar),
		"保存必须顺手写一份缩略图 sidecar（文档 §8「自动缩略图」）：%s" % sidecar)
	var items := _open_items(ed)
	assert_true(items.has(path.get_file()), "真实存档应出现在「打开这个存档」里：%s" % str(items))
	assert_false(items.has(sidecar.get_file()),
		"缩略图 sidecar 不是关卡，不得出现在「打开这个存档」里：%s" % str(items))
	_cleanup_save(path)


func test_second_editor_opens_a_locked_save_read_only() -> void:
	var a := _make_editor()
	var d := _doc5()
	d.title = SMOKE_TITLE
	_bind(a, d)
	a.call("_save")
	var path := str(a.get("_current_path"))
	assert_true(path != "", "前置条件：第一会话应已保存成功")
	# 第二个编辑器会话（不同 owner）打开同一份存档
	var b := _make_editor()
	assert_true(bool(b.call("_load_from_file", path)), "第二会话应能打开这份存档")
	assert_true(bool(b.get("_read_only")), "别人持有锁时必须以**只读**打开")
	assert_eq(str(b.get("_read_only_path")), path, "只读态要记住是哪一份文件被占")
	# 只读态保存：不得覆盖被占用的文件（文案要求的"改标题另存"由用户触发）
	var before := FileAccess.get_file_as_string(path)
	b.call("_save")
	assert_eq(FileAccess.get_file_as_string(path), before, "只读态保存不得覆盖别人正在编辑的文件")
	a.call("_release_lock")
	_cleanup_save(path)


func test_outline_gesture_writes_a_board_shape() -> void:
	# 【文档 §3「手绘轮廓」】画布交“一次手势的连续点列”，编辑器把它刻成棋盘形状。
	# 这里走真实输入路径（按下 → 拖动 → 抬起）——验的正是“信号真的接到 _on_outline_drawn 上、
	# 且写回走的是 _write_board_shape 那条唯一入口”。
	var ed := _make_editor()
	var d := EditorDoc.new(9, 9)
	_bind(ed, d)
	assert_eq(d.obstacles.size(), 0, "起始应是一张全可走的空盘（没有障碍格）")
	var canvas := _canvas_of(ed)
	canvas.size = Vector2(600, 600)
	canvas.tool = EditorCanvas.Tool.OUTLINE
	var a := canvas.cell_rect(Vector2i(2, 2)).get_center()
	var b := canvas.cell_rect(Vector2i(7, 2)).get_center()
	var e := canvas.cell_rect(Vector2i(7, 7)).get_center()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = a
	canvas._gui_input(down)
	for pt in [b, e]:
		var mv := InputEventMouseMotion.new()
		mv.position = pt
		mv.button_mask = MOUSE_BUTTON_MASK_LEFT
		canvas._gui_input(mv)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = e
	canvas._gui_input(up)
	# 口径：格集（三角形内部）= 可走，其余 = 障碍。所以三角形之外的格必须被刻成障碍。
	assert_true(d.obstacles.size() > 0, "轮廓之外的格应被刻成障碍（实际障碍 %d 格）" % d.obstacles.size())
	assert_true(d.obstacles.has(Vector2i(0, 0)), "三角形之外的 (0,0) 应成为障碍")
	assert_false(d.obstacles.has(Vector2i(6, 5)), "三角形内部的 (6,5) 应保持可走")
	assert_true(d.obstacles.size() < 81, "轮廓内部应留下可走的格（否则是把整盘刻死了）")
	var note := ed.get("_text_shape_note") as Label
	assert_not_null(note, "属性页应有形状说明标签（默认专家档 ⇒ 一定建出来了）")
	if note != null:
		assert_true(note.text.begins_with("手绘轮廓"), "说明标签应报告手绘轮廓结果：%s" % note.text)


func test_status_bar_names_every_tool_slot() -> void:
	# 【漂移闸门】工具名表（单一来源 = `_tool_name`）必须覆盖 EditorCanvas.Tool 的**每一个**取值。
	# 新工具追加在枚举末尾却忘了加名字 ⇒ 状态栏会显示“-”（这里当场抓到，而不是等用户看见）。
	var ed := _make_editor()
	_bind(ed, EditorDoc.new(9, 9))
	var canvas := _canvas_of(ed)
	var status := ed.get("_status") as Label
	assert_not_null(status, "应有底部状态栏")
	var expected := ["画笔", "橡皮", "矩形填充", "区域选择", "平移", "直线", "油漆桶", "手绘轮廓", "虫洞配对"]
	assert_eq(expected.size(), 9, "工具名表应与 EditorCanvas.Tool 一样有 9 项（新增工具时这里要一起加）")
	for t in range(expected.size()):
		canvas.tool = t
		ed.call("_refresh_status")
		assert_true(status.text.contains(expected[t]), "工具 %d（%s）时状态栏应报出名字：%s" % [t, expected[t], status.text])


# ==================== 只读分享（文档 §8「只读分享（只能玩不能改）」）====================
# 要钉死的四件事（都是"用户会不会被卡住"的级别）：
#   ① 声明了 editor_meta.read_only 的关卡 ⇒ 载入即只读，且原因要说成"只读分享件"（不是"占用锁"）；
#   ② 原名保存必须被拦下且**不落盘**（"只能玩不能改"就落在这里）；
#   ③ 改标题 ⇒ 能另存成自己的新关卡，**且副本不再是只读**（否则下次打开又只读、每存一次都要改名）；
#   ④ 换了一份没有只读声明的关卡 ⇒ 旧的只读态必须清掉，不然新关卡保存被白拦。
const SMOKE_RO_TITLE := "zz_smoke_readonly_share"


func _ro_level_json(title: String) -> String:
	# 形状口径同 decode 的产出（mines/revealed 为 {r,c}）——编辑器导入走的就是这条口径。
	return JSON.stringify({
		"name": title,
		"size": {"rows": 5, "cols": 5},
		"total_mines": 1,
		"mines": [{"r": 0, "c": 0}],
		"revealed": [],
		"editor_meta": {"read_only": true, "author": "someone"},
	})


func test_read_only_share_blocks_same_name_save_but_allows_save_as() -> void:
	var ed := _make_editor()
	_bind(ed, _doc5())
	assert_true(bool(ed.call("_load_from_text", _ro_level_json(SMOKE_RO_TITLE))),
		"含 editor_meta.read_only 的关卡文本应能载入")
	assert_true(bool(ed.get("_read_only")), "只读分享件载入后必须是只读态")
	assert_eq(str(ed.get("_read_only_reason")), "share",
		"原因必须说成「只读分享件」，不能跟「占用锁」混成一句")
	# ② 原名保存 ⇒ 拦下，且绝不落盘
	var same := "%s/%s.json" % [EDITOR_DIR, SMOKE_RO_TITLE]
	ed.call("_save")
	assert_eq(str(ed.get("_current_path")), "", "只读分享件按原名保存必须被拦下（不得认领成当前文件）")
	assert_false(FileAccess.file_exists(same), "被拦下的保存不得留下文件：%s" % same)
	# ③ 改标题 ⇒ 另存成自己的新关卡（这是文档承诺的唯一出路，必须真的走得通）
	var copy_title := SMOKE_RO_TITLE + "_copy"
	ed.doc.title = copy_title
	ed.call("_save")
	var p := str(ed.get("_current_path"))
	assert_eq(p, "%s/%s.json" % [EDITOR_DIR, copy_title], "改了标题就该另存成新文件")
	assert_true(FileAccess.file_exists(p), "另存应真的落盘：%s" % p)
	# 副本不能再带只读声明，否则"导入的别人的关卡可二次编辑"（§8）整条作废
	var reloaded: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	assert_true(reloaded is Dictionary, "另存出来的应是合法关卡 JSON")
	assert_false(ShareCode.read_only_of(reloaded as Dictionary),
		"另存出来的副本应是**可编辑**的：只读声明不该跟着写进用户自己的文件")
	_cleanup_save(p)
	_cleanup_save(same)


func test_loading_a_plain_level_clears_the_read_only_state() -> void:
	var ed := _make_editor()
	_bind(ed, _doc5())
	assert_true(bool(ed.call("_load_from_text", _ro_level_json(SMOKE_RO_TITLE))),
		"前置条件：先进入只读分享态")
	assert_true(bool(ed.get("_read_only")), "前置条件：确实进了只读态")
	var plain := {
		"name": "zz_smoke_plain_after_ro",
		"size": {"rows": 5, "cols": 5},
		"total_mines": 0,
		"mines": [],
		"revealed": [],
	}
	assert_true(bool(ed.call("_load_from_text", JSON.stringify(plain))), "普通关卡文本应能载入")
	assert_false(bool(ed.get("_read_only")), "换了一份没有只读声明的关卡 ⇒ 旧的只读态必须清掉")
	assert_eq(str(ed.get("_read_only_reason")), "", "原因也要清空（否则下次被拦会给错话）")
	# 清掉之后就该能正常保存（这里只验"没被当成只读件拦下"）
	ed.call("_save")
	var p := str(ed.get("_current_path"))
	assert_true(p != "", "非只读关卡应能正常保存（实际 %s）" % p)
	_cleanup_save(p)

# 「只读分享」勾选对**文本形式**（复制关卡文本）的生效路径。
# 走 `_share_text_for_export` 而不是按按钮：无头环境没有剪贴板（`_clipboard_available()` 为假），
# 直接验“要复制的内容”既稳定，又正好钉住真正要保证的那件事——文本里带不带只读声明。
func _read_only_of_text(text: String) -> bool:
	var d: Variant = JSON.parse_string(text)
	if not (d is Dictionary):
		return false
	return ShareCode.read_only_of(d as Dictionary)


func test_read_only_checkbox_stamps_the_text_form_too() -> void:
	var ed := _make_editor()
	_bind(ed, _doc5())
	var chk := ed.get("_share_readonly_chk") as CheckButton
	assert_not_null(chk, "分享面板应有「只读分享」勾选框")
	if chk == null:
		return
	assert_false(chk.button_pressed, "默认必须是**不勾**（默认可编辑，不许悄悄变只读）")
	assert_false(_read_only_of_text(str(ed.call("_share_text_for_export"))),
		"没勾 ⇒ 关卡文本里不该有只读声明")
	chk.button_pressed = true
	assert_true(_read_only_of_text(str(ed.call("_share_text_for_export"))),
		"勾了 ⇒ 关卡文本形式也必须带只读声明（否则这一路就“说了不做”）")
# ==================== 填充空隙（文档 §3「填充系统」） ====================

## 属性页必须有「填充空隙」区，且默认档就是"把洞补回来"（区域 = 障碍（洞）、挖去 = 空集）。
func test_fill_section_is_wired_with_fill_the_holes_defaults() -> void:
	var ed := _make_editor()
	_bind(ed, _doc5())
	var area := ed.get("_fill_area_opt") as OptionButton
	var hole := ed.get("_fill_hole_opt") as OptionButton
	var mode := ed.get("_fill_mode_opt") as OptionButton
	var unit := ed.get("_fill_unit_opt") as OptionButton
	assert_not_null(area, "应有「区域」下拉")
	assert_not_null(hole, "应有「挖去」下拉")
	assert_not_null(mode, "应有填充样式下拉（实心 / 环形 / 图案）")
	assert_not_null(unit, "应有图案单元下拉")
	assert_not_null(ed.get("_fill_note"), "应有常驻结果文案（失败必须有可读文案）")
	if area == null or hole == null or mode == null:
		return
	assert_eq(str(area.get_item_metadata(area.selected)), "__obstacles__",
		"「区域」默认应是「障碍（洞）」——直接点按钮就是把挖掉的洞补回来")
	assert_eq(str(hole.get_item_metadata(hole.selected)), "__empty__",
		"「挖去」默认应是「空集」（空集是合法输入，不需要先框选）")
	assert_eq(mode.item_count, 3, "样式应有三档：实心 / 环形 / 图案")
	assert_eq(str(ed.call("_fill_mode_key")), "solid", "默认样式应是实心")


## 「填充」按钮的真往返：挖掉两个洞 → 点填充 → 洞被补回、盘回到满格。
func test_fill_button_turns_carved_holes_back_into_cells() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(5, 5)
	d.obstacles.append(Vector2i(4, 4))
	d.obstacles.append(Vector2i(0, 4))
	_bind(ed, d)
	assert_eq(d.grid().cell_count(), 23, "前置：5×5 挖掉 2 格 = 23 格")
	assert_false(d.grid().in_board(Vector2i(4, 4)), "前置：(4,4) 应是洞")
	ed.call("_on_fill_gap")
	assert_eq(d.obstacles.size(), 0, "填充应把两个洞都补回来（障碍清空）")
	assert_eq(d.grid().cell_count(), 25, "补完应是满盘 25 格")
	assert_true(d.grid().in_board(Vector2i(4, 4)), "(4,4) 应重新变成盘上的格")


## 手工改过的格是硬约束：填充**不得覆盖**它，而且必须说出来（不许静默忽略）。
func test_fill_never_overwrites_hand_edited_cells_and_says_so() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(5, 5)
	d.obstacles.append(Vector2i(4, 4))
	_bind(ed, d)
	var hand: Dictionary = ed.get("_hand_edited")
	hand[Vector2i(4, 4)] = true          # 标成"已脱离生成"
	ed.call("_on_fill_gap")
	assert_eq(d.obstacles.size(), 1, "手工改过的洞不许被填充覆盖")
	assert_false(d.grid().in_board(Vector2i(4, 4)), "该格应仍是洞")
	var note := ed.get("_fill_note") as Label
	assert_not_null(note, "应有常驻文案")
	var text := str(note.text) if note != null else ""
	assert_true(text.contains("跳过"),
		"跳过手工格必须说出来（实际文案：%s）" % text)


## 属性页必须有「边缘平滑」区：默认档 = 框选区域，且**不列**障碍 / 空集
##（那两个是「格存在」的补集，拿来平滑只会空转 = 假功能）。
func test_smooth_section_is_wired_and_hides_the_complement_sets() -> void:
	var ed := _make_editor()
	_bind(ed, _doc5())
	var src := ed.get("_smooth_src_opt") as OptionButton
	assert_not_null(src, "应有「作用对象」下拉")
	assert_not_null(ed.get("_smooth_note"), "应有常驻结果文案（被拒绝时要有可读文案 + 问题格）")
	if src == null:
		return
	assert_eq(str(src.get_item_metadata(src.selected)), "__selection__", "默认「作用对象」应是框选区域")
	var keys: Array[String] = []
	for i in src.item_count:
		keys.append(str(src.get_item_metadata(i)))
	assert_true(keys.has("__board__"), "应能对「整盘形状」做平滑")
	assert_false(keys.has("__obstacles__"), "障碍（洞）是补集，平滑不该把它列进作用对象（选了是空转）")
	assert_false(keys.has("__empty__"), "空集同样不该列出来")


## 「膨胀一圈」的真往返：挖掉中央 3×3 → 对整盘形状膨胀 → 外沿一圈补回、只剩正中 1 格是洞。
func test_smooth_dilate_turns_the_hole_rim_back_into_cells() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(5, 5)
	for y in range(1, 4):
		for x in range(1, 4):
			d.obstacles.append(Vector2i(x, y))
	_bind(ed, d)
	assert_eq(d.grid().cell_count(), 16, "前置：5×5 挖掉中央 3×3 = 16 格")
	_opt_pick(ed.get("_smooth_src_opt") as OptionButton, "__board__")
	ed.call("_on_smooth", "dilate")
	assert_eq(d.obstacles.size(), 1, "膨胀应把洞的外沿一圈补回来（9 → 1）")
	assert_false(d.grid().in_board(Vector2i(2, 2)), "正中那一格仍是洞（膨胀只够得到外沿）")
	assert_true(d.grid().in_board(Vector2i(1, 1)), "(1,1) 应重新变成盘上的格")
	var note := ed.get("_smooth_note") as Label
	var text := str(note.text) if note != null else ""
	assert_true(text.contains("膨胀"), "常驻文案要说出做了什么（实际：%s）" % text)


## 按元数据 key 选中下拉的某一项（本文件多个用例用）。
func _opt_pick(opt: OptionButton, key: String) -> void:
	if opt == null:
		return
	for i in opt.item_count:
		if str(opt.get_item_metadata(i)) == key:
			opt.selected = i
			return


# ==================== 拓扑 · 虫洞配对（文档「拓扑玩法」）====================

## 虫洞配对：连点两格 = 一对（一步撤销 = 一对），撤销后能回到"还没配"的状态。
##
## 【为什么必须走真实路径而不是直接 `doc.portals.append`】撤销点取在"改动**之前**"这条契约，
## 只有 UI 层的 `_on_portal_clicked` 负责兑现；绕过它直接写 doc，就把这条契约漏掉了
##（本仓"按一次撤销等于没动"的旧缺陷就是这么来的）。
func test_portal_pairing_two_clicks_then_undo() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(5, 5)
	for m in [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)]:
		d.mines.append(m)
	_bind(ed, d)
	var canvas := _canvas_of(ed)
	canvas.tool = EditorCanvas.Tool.PORTAL

	ed.call("_on_portal_clicked", Vector2i(0, 4))
	assert_eq(d.portals.size(), 0, "只点一格不得成对")
	assert_eq(canvas.portal_pending, Vector2i(0, 4), "第一端应记成 pending（画布上也要标出来）")

	ed.call("_on_portal_clicked", Vector2i(4, 0))
	assert_eq(d.portals.size(), 2, "第二端点下去应成一对（扁平 [a, b]）")
	assert_true(d.portals.has(Vector2i(0, 4)) and d.portals.has(Vector2i(4, 0)), "两端坐标要写进文档")
	assert_eq(canvas.portal_pending, Vector2i(-1, -1), "成对后 pending 必须清空")

	# 撤销：回到"还没配对"（撤销点取在改动之前）
	ed.call("_undo_once")
	assert_eq((ed.get("doc") as EditorDoc).portals.size(), 0, "撤销一次应回到未配对状态")
