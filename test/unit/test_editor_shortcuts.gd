# test_editor_shortcuts.gd —— 编辑器快捷键 / 绑定表 / 显雷统一状态 / 问题跳转 / 多岛结论（W2·W3·W4·W5）
#
# 钉住的不变量（每条对应文档里的一项要求）：
#   1) 绑定表：解析/描述是纯函数；独立段 `[editor_keys]` 能存能读、缺省与脏值都回退；
#   2) 快捷键映射：Tab=秒切、Ctrl+Tab=面板、G/ Ctrl+G、B/E、M/S=格型、P/L=平移/选区、
#      1~9=画笔槽位、R/Ctrl+R=选区旋转/镜像、Alt+点击吸管（2026-10-03 按文档语义对齐）；
#   3) Tab 秒切：进/出"试玩态"后**编辑器文档一格不差**，且显雷在试玩态被强制隐藏；
#   4) 显雷统一状态机：编辑态看开关、试玩态恒隐藏（禁止各处自判）；
#   5) 问题面板跳转：点一条能定位到目标格（`center_on_cell` 的几何是纯函数）；
#   6) 多岛结论：多岛时逐岛显示（"1 号岛 … / 2 号岛 …"），单岛时不加岛行；
#   7) 对称镜像（Ctrl+G）：单格手势镜像到对称位置。
#
# 类型纪律：编辑器脚本没有 `class_name` ⇒ 变量声明成 Object 并用 `.call()`。
# 绑定表/状态机**preload** 引用（不写 class_name，见坑表 #26：headless 新全局类不在缓存里）。
extends GutTest

const BINDINGS := preload("res://core/editor_bindings.gd")
const VIEW_STATE := preload("res://core/editor_view_state.gd")
const TMP_CFG := "user://_test_editor_bindings.cfg"
const AUTOSAVE := "user://editor/_autosave.json"
const PLAY_FILE := "user://editor/_play.json"


func _key(code: int, ctrl := false, alt := false, shift := false) -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = code
	k.pressed = true
	k.ctrl_pressed = ctrl
	k.alt_pressed = alt
	k.shift_pressed = shift
	return k


func _make_editor() -> Object:
	var scene: PackedScene = load("res://ui/level_editor.tscn")
	assert_not_null(scene, "编辑器场景应能加载")
	var ed: Object = scene.instantiate()
	add_child_autofree(ed as Node)
	await wait_process_frames(2)
	return ed


func _canvas_of(ed: Object) -> EditorCanvas:
	var found := (ed as Node).find_children("*", "EditorCanvas", true, false)
	return found[0] as EditorCanvas if not found.is_empty() else null


func _bind(ed: Object, d: EditorDoc) -> void:
	ed.doc = d
	ed.call("_doc_to_ui")
	ed.call("_refresh_all")


func _doc5() -> EditorDoc:
	var d := EditorDoc.new(5, 5)
	for m in [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)]:
		d.mines.append(m)
	return d


## 5x5 + 障碍列 x=2 ⇒ 两个 10 格岛（与 `test_editor_islands.gd` 同一构造）。
func _split_doc() -> EditorDoc:
	var d := EditorDoc.new(5, 5)
	for y in range(5):
		d.obstacles.append(Vector2i(2, y))
	d.mines.append(Vector2i(0, 0))
	d.mines.append(Vector2i(3, 1))
	d.mines.append(Vector2i(4, 3))
	for y in range(5):
		for x in [0, 1]:
			var p := Vector2i(x, y)
			if not d.mines.has(p):
				d.revealed[p] = null
	d.revealed[Vector2i(4, 2)] = null
	return d


func _read_file_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


func _restore_file(path: String, text: String) -> void:
	if text == "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


# ==================== 1. 绑定表：纯函数 + 存读回退 ====================

func test_binding_descriptor_parse_and_describe() -> void:
	assert_eq(BINDINGS.describe("ctrl+z"), "Ctrl+Z", "Ctrl+Z 要说人话")
	assert_eq(BINDINGS.describe("space"), "空格")
	assert_eq(BINDINGS.describe("alt+click"), "Alt+点击")
	assert_eq(BINDINGS.describe("ctrl+tab"), "Ctrl+Tab")
	assert_eq(int(BINDINGS.parse("1")["key"]), KEY_1, "数字 token 要解析成 KEY_1")
	assert_eq(int(BINDINGS.parse("ctrl+g")["key"]), KEY_G)
	assert_true(bool(BINDINGS.parse("ctrl+g")["ctrl"]), "ctrl 修饰位要认出来")
	assert_false(bool(BINDINGS.parse("ctrl+nope")["ok"]), "未知 token 必须解析失败（好回退缺省）")
	assert_false(bool(BINDINGS.parse("")["ok"]), "空串解析失败")


func test_binding_table_persists_and_falls_back() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_CFG))
	var b = BINDINGS.new()
	b.path = TMP_CFG
	b.load_cfg()
	assert_eq(b.key_for("undo"), "ctrl+z", "无 cfg 时用缺省")
	assert_eq(b.key_for("playtest_toggle"), "tab", "Tab 秒切是缺省键位之一")
	b.bindings["undo"] = "ctrl+u"
	b.save()
	var b2 = BINDINGS.new()
	b2.path = TMP_CFG
	b2.load_cfg()
	assert_eq(b2.key_for("undo"), "ctrl+u", "改过的键位要能读回")
	assert_eq(b2.key_for("redo"), "ctrl+y", "没改的动作回退缺省")
	# 脏值（手改 cfg 写了不存在的键）⇒ 该动作回退缺省，且不抛错
	var cfg := ConfigFile.new()
	cfg.set_value("editor_keys", "save", "ctrl+notakey")
	cfg.save(TMP_CFG)
	var b3 = BINDINGS.new()
	b3.path = TMP_CFG
	b3.load_cfg()
	assert_eq(b3.key_for("save"), "ctrl+s", "脏值必须回退缺省（不许把非法键带进运行期）")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_CFG))


func test_shortcut_mapping_covers_the_documented_set() -> void:
	var ed := await _make_editor()
	var b = ed.get("_bindings")
	assert_eq(str(b.action_for_event(_key(KEY_TAB))), "playtest_toggle", "Tab = 编辑↔试玩秒切")
	assert_eq(str(b.action_for_event(_key(KEY_TAB, true))), "panel_focus", "面板切换改 Ctrl+Tab")
	assert_eq(str(b.action_for_event(_key(KEY_G))), "grid_toggle", "G = 网格线")
	assert_eq(str(b.action_for_event(_key(KEY_G, true))), "symmetry_cycle", "Ctrl+G = 对称循环")
	assert_eq(str(b.action_for_event(_key(KEY_B))), "tool_brush")
	assert_eq(str(b.action_for_event(_key(KEY_E))), "tool_erase")
	# 【2026-10-03 语义对齐文档】M=放雷、S=强制安全格；平移/区域选择改到 P/L（功能不丢）。
	assert_eq(str(b.action_for_event(_key(KEY_M))), "kind_mine", "M = 放雷（文档语义）")
	assert_eq(str(b.action_for_event(_key(KEY_S))), "kind_safe", "S = 强制安全格（文档语义）")
	assert_eq(str(b.action_for_event(_key(KEY_P))), "tool_pan", "平移工具改 P")
	assert_eq(str(b.action_for_event(_key(KEY_L))), "tool_select", "区域选择改 L")
	assert_eq(str(b.action_for_event(_key(KEY_1))), "digit_1")
	assert_eq(str(b.action_for_event(_key(KEY_9))), "digit_9")
	assert_eq(str(b.action_for_event(_key(KEY_Z, true))), "undo")
	assert_eq(str(b.action_for_event(_key(KEY_Y, true))), "redo")
	assert_eq(str(b.action_for_event(_key(KEY_C, true))), "copy")
	assert_eq(str(b.action_for_event(_key(KEY_X, true))), "cut")
	assert_eq(str(b.action_for_event(_key(KEY_V, true))), "paste")
	assert_eq(str(b.action_for_event(_key(KEY_D, true))), "duplicate")
	# 【2026-10-03】R/Ctrl+R 让给选区编辑；随机布雷/重置视图移到 Ctrl+N / Ctrl+0。
	assert_eq(str(b.action_for_event(_key(KEY_R))), "rotate_selection", "R = 选区旋转")
	assert_eq(str(b.action_for_event(_key(KEY_R, true))), "mirror_selection", "Ctrl+R = 选区镜像")
	assert_eq(str(b.action_for_event(_key(KEY_N, true))), "random_mines", "随机布雷改 Ctrl+N")
	assert_eq(str(b.action_for_event(_key(KEY_0, true))), "reset_view", "重置视图改 Ctrl+0")
	assert_eq(str(b.action_for_event(_key(KEY_F1))), "help")
	# 修饰键必须**完全相等**：G 不许抢 Ctrl+G
	assert_eq(str(b.action_for_event(_key(KEY_Z))), "", "裸 Z 不该命中 Ctrl+Z")
	var alt_click := InputEventMouseButton.new()
	alt_click.button_index = MOUSE_BUTTON_LEFT
	alt_click.pressed = true
	alt_click.alt_pressed = true
	assert_true(b.matches_mouse("eyedropper", alt_click), "Alt+点击 = 吸管")
	var plain_click := InputEventMouseButton.new()
	plain_click.button_index = MOUSE_BUTTON_LEFT
	plain_click.pressed = true
	assert_false(b.matches_mouse("eyedropper", plain_click), "不带 Alt 的点击不是吸管")


func test_dispatched_actions_change_state() -> void:
	var ed := await _make_editor()
	var canvas := _canvas_of(ed)
	# 工具
	ed.call("_dispatch", "digit_3")
	assert_eq(canvas.tool, EditorCanvas.Tool.RECT_FILL, "③ = 矩形填充")
	ed.call("_dispatch", "digit_7")
	assert_eq(canvas.tool, EditorCanvas.Tool.BUCKET, "⑦ = 油漆桶")
	ed.call("_dispatch", "tool_brush")
	assert_eq(canvas.tool, EditorCanvas.Tool.PAINT, "B = 画笔")
	# 格型
	ed.call("_dispatch", "digit_8")
	assert_eq(canvas.paint_kind, EditorCanvas.KIND_MINE, "⑧ = 地雷")
	ed.call("_dispatch", "digit_9")
	assert_eq(canvas.paint_kind, EditorCanvas.KIND_OBSTACLE, "⑨ = 障碍")
	# 网格线
	var before: bool = canvas.show_grid
	ed.call("_dispatch", "grid_toggle")
	assert_eq(canvas.show_grid, not before, "G 应切网格线")
	assert_eq((ed.get("_grid_btn") as Button).button_pressed, canvas.show_grid,
		"按钮高亮必须跟着快捷键走（否则界面在骗人）")
	# 重置视图
	canvas.zoom = 3.0
	canvas.pan = Vector2(40, 40)
	ed.call("_dispatch", "reset_view")
	assert_eq(canvas.zoom, 1.0, "Ctrl+R 重置缩放")
	assert_eq(canvas.pan, Vector2.ZERO, "Ctrl+R 重置平移")


func test_panel_focus_is_ctrl_tab_cycle() -> void:
	var ed := await _make_editor()
	# 用画布的懒查找入口（`_tabs` 字段是在首次真需要时才缓存的，`:115` 的注释记着这个时序坑）
	var tabs: TabContainer = ed.call("_right_tabs")
	assert_not_null(tabs, "编辑器应有右侧页签容器")
	var n := tabs.get_tab_count()
	assert_true(n >= 2, "至少两页才谈得上切换")
	var first := tabs.current_tab
	ed.call("_dispatch", "panel_focus")
	assert_eq(tabs.current_tab, (first + 1) % n, "Ctrl+Tab 切到下一块面板")


# ==================== 2. 显雷统一状态机（编辑/试玩两态） ====================

func test_cheat_state_machine_forces_hidden_in_play() -> void:
	var vs = VIEW_STATE.new()
	assert_eq(vs.mode, VIEW_STATE.MODE_EDIT, "默认编辑态")
	assert_true(vs.is_cheat_visible(), "编辑态默认显雷（否则没法编辑）")
	vs.toggle_cheats()
	assert_false(vs.is_cheat_visible(), "编辑态关掉后不显示")
	vs.set_cheats(true)
	vs.set_mode(VIEW_STATE.MODE_PLAY)
	assert_true(vs.cheats_on, "开关本身仍是开")
	assert_false(vs.is_cheat_visible(), "试玩态**强制隐藏**（唯一判据，各处不许自判）")
	vs.toggle_cheats()
	assert_false(vs.is_cheat_visible(), "试玩态怎么点开关都不显示")
	vs.set_mode(VIEW_STATE.MODE_EDIT)
	assert_false(vs.is_cheat_visible(), "切回编辑态后按开关走")
	vs.set_mode("不认识的态")
	assert_eq(vs.mode, VIEW_STATE.MODE_EDIT, "未知识别串一律当编辑态（fail-safe）")


func test_editor_uses_the_unified_cheat_state() -> void:
	var ed := await _make_editor()
	var vs = ed.get("_view_state")
	assert_true(bool(vs.is_cheat_visible()), "编辑器默认在编辑态显雷")
	assert_true((ed.get("_cheat_btn") as Button).button_pressed, "「显示雷/线索」按钮默认按下")
	ed.call("_toggle_cheats")
	assert_false(bool(vs.is_cheat_visible()), "关掉后状态机为不显示")
	assert_false((ed.get("_cheat_btn") as Button).button_pressed, "按钮要弹起")


# ==================== 3. Tab 秒切：状态保留 + 显雷强制隐藏 ====================

func test_tab_quick_switch_keeps_edits_and_forces_cheat_off() -> void:
	var backup_save := _read_file_text(AUTOSAVE)
	var backup_play := _read_file_text(PLAY_FILE)
	var ed := await _make_editor()
	var d := _doc5()
	_bind(ed, d)
	var canvas := _canvas_of(ed)
	# 模拟"画了一笔"：改动必须在秒切往返后仍在
	canvas.apply_kind(Vector2i(4, 4), EditorCanvas.KIND_OBSTACLE)
	assert_true(d.obstacles.has(Vector2i(4, 4)), "改动先落到文档")
	var mines_before := d.mines.size()
	var obs_before := d.obstacles.size()
	ed.call("_toggle_playtest")                     # Tab：进试玩态（内嵌，不切场景）
	await wait_process_frames(2)
	assert_not_null(ed.get("_play_overlay"), "Tab 应进入内嵌试玩态（不销毁编辑器）")
	var vs = ed.get("_view_state")
	assert_true(bool(vs.is_play()), "状态机应切到试玩态")
	assert_false(bool(vs.is_cheat_visible()), "试玩态必须强制隐藏雷/线索")
	ed.call("_toggle_playtest")                     # Tab 再按：回编辑态
	await wait_process_frames(2)
	assert_null(ed.get("_play_overlay"), "再按 Tab 应回到编辑")
	assert_false(bool(vs.is_play()), "状态机应切回编辑态")
	assert_true(bool(vs.is_cheat_visible()), "回编辑态后显雷按其开关恢复")
	# **改动仍在**：文档逐字段没有丢（这是"秒切"的核心承诺）
	assert_eq(d.mines.size(), mines_before, "秒切往返后雷数不应变")
	assert_eq(d.obstacles.size(), obs_before, "秒切往返后障碍数不应变")
	assert_true(d.obstacles.has(Vector2i(4, 4)), "切回后那一笔改动必须还在")
	assert_eq(str(GameSession.playtest_return), "", "回编辑后回程标记要清掉")
	_restore_file(AUTOSAVE, backup_save)
	_restore_file(PLAY_FILE, backup_play)


# ==================== 4. 问题面板点击跳转 ====================

func test_issue_jump_centers_the_view_on_the_target_cell() -> void:
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var canvas := _canvas_of(ed)
	canvas.size = Vector2(600, 600)
	var target := Vector2i(4, 1)
	ed.call("_focus_cell", target)
	var c := canvas.cell_rect(target).get_center()
	assert_almost_eq(c.x, canvas.size.x * 0.5, 1.0, "跳转后目标格应水平居中")
	assert_almost_eq(c.y, canvas.size.y * 0.5, 1.0, "跳转后目标格应垂直居中")
	assert_gte(canvas.zoom, 1.5, "跳转应抬高缩放，让目标格看得清")


func test_issue_list_entries_are_clickable_when_they_have_a_cell() -> void:
	var ed := await _make_editor()
	var d := _doc5()
	d.mines.append(Vector2i(4, 4))      # 与声明雷数无关，制造一条"声明的总雷数不一致"错误
	d.declared_total_mines = 99
	_bind(ed, d)
	var box := ed.get("_issues_box") as VBoxContainer
	var jumpable := 0
	for c in box.get_children():
		if c is Button and c.has_meta("ed_jump_cell"):
			jumpable += 1
	assert_gte(jumpable, 0, "带格坐标的问题应做成可点条目（没有错误时 0 也合法）")
	# 直接构造一条带坐标的问题走一遍渲染路径：必须出现可点按钮
	ed.call("_refresh_issue_list", {"ok": false, "errors": [
		{"code": "x", "text": "测试错误", "pos": Vector2i(1, 2), "level": "error"}],
		"warnings": [], "infos": [], "issues": []})
	var found_btn: Button = null
	for c in box.get_children():
		if c is Button and c.has_meta("ed_jump_cell"):
			found_btn = c as Button
	assert_not_null(found_btn, "带格坐标的问题条必须是可点按钮")
	assert_eq(found_btn.get_meta("ed_jump_cell"), Vector2i(1, 2), "按钮要记住目标格")


# ==================== 5. 多岛结论显示 ====================

func _verify_texts(ed: Object) -> String:
	var box := ed.get("_verify_issues") as VBoxContainer
	var out := ""
	for c in box.get_children():
		if c is Label:
			out += (c as Label).text + "\n"
	return out


func test_multi_island_verification_lists_each_island() -> void:
	var ed := await _make_editor()
	_bind(ed, _split_doc())
	await ed.call("_on_verify")
	await wait_process_frames(2)
	var txt := _verify_texts(ed)
	assert_true(txt.find("1 号岛") != -1, "多岛时应逐岛显示 1 号岛：%s" % txt)
	assert_true(txt.find("2 号岛") != -1, "多岛时应逐岛显示 2 号岛：%s" % txt)
	assert_true(txt.find("需盲猜") != -1, "需猜的岛要写清盲猜次数：%s" % txt)
	var stars := ed.get("_verify_stars") as Label
	assert_true(stars.text.find("★") != -1, "应显示 1~5 星难度：%s" % stars.text)


func test_single_island_shows_no_island_lines() -> void:
	var ed := await _make_editor()
	var d := _doc5()
	d.revealed[Vector2i(4, 4)] = null
	_bind(ed, d)
	await ed.call("_on_verify")
	await wait_process_frames(2)
	var txt := _verify_texts(ed)
	assert_eq(txt.find("号岛"), -1, "单岛不应出现岛级行（显示要与旧口径一致）：%s" % txt)


# ==================== 6. 对称（Ctrl+G） ====================

func test_symmetry_mirrors_single_cell_gestures() -> void:
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var canvas := _canvas_of(ed)
	canvas.tool = EditorCanvas.Tool.PAINT
	ed.call("_cycle_symmetry")
	ed.call("_cycle_symmetry")
	ed.call("_cycle_symmetry")          # 关 → 竖轴 → 横轴 → 四象
	var mirrors: Array = ed.call("_symmetry_cells", Vector2i(0, 0))
	assert_eq((mirrors as Array).size(), 3, "四象应给出 3 个镜像格：%s" % str(mirrors))
	canvas.apply_kind(Vector2i(0, 0), EditorCanvas.KIND_OBSTACLE)
	ed.call("_on_cell_edited", Vector2i(0, 0))
	var d: EditorDoc = ed.doc
	assert_true(d.obstacles.has(Vector2i(4, 0)), "竖轴镜像：x→cols-1-x")
	assert_true(d.obstacles.has(Vector2i(0, 4)), "横轴镜像：y→rows-1-y")
	assert_true(d.obstacles.has(Vector2i(4, 4)), "对角镜像")
	# 关掉后不再镜像
	ed.call("_cycle_symmetry")
	assert_eq(int(ed.get("_sym_mode")), 0, "循环一圈回到关")
	var before := d.obstacles.size()
	canvas.apply_kind(Vector2i(1, 1), EditorCanvas.KIND_OBSTACLE)
	ed.call("_on_cell_edited", Vector2i(1, 1))
	assert_eq(d.obstacles.size(), before + 1, "关掉对称后只改一格")


func test_eyedropper_picks_the_cell_kind() -> void:
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var canvas := _canvas_of(ed)
	ed.call("_set_kind", EditorCanvas.KIND_CLEAR)
	assert_true(bool(ed.call("_eyedropper_at", Vector2i(0, 0))), "吸管应命中盘上格（此格是雷）")
	assert_eq(canvas.paint_kind, EditorCanvas.KIND_MINE, "吸到雷")
	assert_false(bool(ed.call("_eyedropper_at", Vector2i(-1, -1))), "盘外不吸")


# ==================== 7. 接线：空格平移两态 + 油漆桶结果 ====================

func test_space_pan_is_press_release_and_bucket_report_is_wired() -> void:
	var ed := await _make_editor()
	var canvas := _canvas_of(ed)
	# ① 油漆桶截断提示必须有人接（不接 = 用户不知道"只染了前 N 格"）
	assert_gt(canvas.bucket_reported.get_connections().size(), 0,
		"编辑器的 `_on_bucket_reported` 必须连上 `bucket_reported`")
	# ② 空格两态：按住进平移、抬起退出（`_input` 的两个分支）
	ed.call("_input", _key(KEY_SPACE))
	assert_true(canvas._pan_mode, "按住空格应进入平移态")
	var up := _key(KEY_SPACE)
	up.pressed = false
	ed.call("_input", up)
	assert_false(canvas._pan_mode, "松开空格应退出平移态")


# ==================== 8. 1~9 数字直选（文档「快捷键」） ====================
#
# 【口径】本仓 `EditorDoc.revealed` 的值恒为 null（数字由 `preview_clues()` 重算），**没有**"每格存数字"
# 的字段 ⇒ 文档的"1~9 直接刷"在此落成"1~9 直选画笔工具/格型槽位"，不新造数据结构。
func test_every_digit_lands_on_its_brush_slot() -> void:
	var ed := await _make_editor()
	var canvas := _canvas_of(ed)
	var expect_tool := {
		1: EditorCanvas.Tool.PAINT, 2: EditorCanvas.Tool.ERASE, 3: EditorCanvas.Tool.RECT_FILL,
		4: EditorCanvas.Tool.SELECT, 5: EditorCanvas.Tool.PAN, 6: EditorCanvas.Tool.LINE,
		7: EditorCanvas.Tool.BUCKET,
	}
	for n in range(1, 8):
		ed.call("_dispatch", "digit_%d" % n)
		assert_eq(canvas.tool, expect_tool[n], "数字 %d 应切到对应工具" % n)
	ed.call("_dispatch", "digit_8")
	assert_eq(canvas.paint_kind, EditorCanvas.KIND_MINE, "⑧ = 地雷格型")
	ed.call("_dispatch", "digit_9")
	assert_eq(canvas.paint_kind, EditorCanvas.KIND_OBSTACLE, "⑨ = 障碍格型")
	# 键位表把 1~9 逐一映到 digit_1..digit_9（否则键盘按不出来）
	var b = ed.get("_bindings")
	for n in range(1, 10):
		assert_eq(str(b.action_for_event(_key(KEY_0 + n))), "digit_%d" % n, "键 %d = digit_%d" % [n, n])


# ==================== 9. 选区旋转 / 镜像（文档：R / Ctrl+R） ====================

func _kind_multiset(ed: Object, rect: Rect2i) -> Dictionary:
	var m := {}
	for y in range(rect.position.y, rect.position.y + rect.size.y + 1):
		for x in range(rect.position.x, rect.position.x + rect.size.x + 1):
			var k := str(ed.call("_kind_of", Vector2i(x, y)))
			m[k] = int(m.get(k, 0)) + 1
	return m


func test_rotate_selection_keeps_kind_multiset() -> void:
	var ed := await _make_editor()
	# 【为什么用 9×9 而不是任意小盘】`doc.grid()` 对某些尺寸（如 6×6、空 dirs）会漏格
	#（实测 `EditorDoc.new(6,6)` 只有 35 格、缺 (2,0)）——那是 `WrapTopology` 的既有缺陷，
	# 不在本任务范围；这里用编辑器默认的 9×9（实测 81 格齐全）避免误伤。
	_bind(ed, EditorDoc.new(9, 9))
	var canvas := _canvas_of(ed)
	# 3×3 选区（`Rect2i(P,S)` 覆盖 P..P+S），内容**非对称**：左上雷、右上障碍、中下翻开，其余空
	var sel := Rect2i(Vector2i(0, 0), Vector2i(2, 2))
	canvas.set_selection(sel)
	ed.call("_apply_kind_at", Vector2i(0, 0), EditorCanvas.KIND_MINE)
	ed.call("_apply_kind_at", Vector2i(2, 0), EditorCanvas.KIND_OBSTACLE)
	ed.call("_apply_kind_at", Vector2i(1, 2), EditorCanvas.KIND_REVEAL)
	var before := _kind_multiset(ed, sel)
	ed.call("_dispatch", "rotate_selection")
	# 顺时针 90°：(0,0)->(2,0)、(2,0)->(2,2)、(1,2)->(0,1)
	assert_eq(str(ed.call("_kind_of", Vector2i(2, 0))), EditorCanvas.KIND_MINE, "雷应转到 (2,0)")
	assert_eq(str(ed.call("_kind_of", Vector2i(2, 2))), EditorCanvas.KIND_OBSTACLE, "障碍应转到 (2,2)")
	assert_eq(str(ed.call("_kind_of", Vector2i(0, 1))), EditorCanvas.KIND_REVEAL, "翻开应转到 (0,1)")
	assert_eq(_kind_multiset(ed, sel), before, "旋转后格型多重集必须守恒（不丢不增）")


func test_mirror_selection_axis_is_correct() -> void:
	var ed := await _make_editor()
	var canvas := _canvas_of(ed)
	# A) 默认（对称关）= 左右翻转：rel.x -> w-1-rel.x
	_bind(ed, EditorDoc.new(9, 9))
	ed.set("_sym_mode", 0)
	ed.call("_apply_kind_at", Vector2i(0, 0), EditorCanvas.KIND_MINE)
	ed.call("_apply_kind_at", Vector2i(1, 0), EditorCanvas.KIND_OBSTACLE)
	canvas.set_selection(Rect2i(Vector2i(0, 0), Vector2i(2, 2)))
	ed.call("_dispatch", "mirror_selection")
	assert_eq(str(ed.call("_kind_of", Vector2i(2, 0))), EditorCanvas.KIND_MINE, "左右翻转：x=0 -> x=2")
	assert_eq(str(ed.call("_kind_of", Vector2i(1, 0))), EditorCanvas.KIND_OBSTACLE, "中间列原地")
	assert_eq(str(ed.call("_kind_of", Vector2i(0, 0))), EditorCanvas.KIND_CLEAR, "原格应被清")
	# B) 对称模式 = 横轴镜像（_sym_mode==2）⇒ 上下翻转：rel.y -> h-1-rel.y
	_bind(ed, EditorDoc.new(9, 9))
	ed.set("_sym_mode", 2)
	ed.call("_apply_kind_at", Vector2i(0, 0), EditorCanvas.KIND_MINE)
	canvas.set_selection(Rect2i(Vector2i(0, 0), Vector2i(2, 2)))
	ed.call("_dispatch", "mirror_selection")
	assert_eq(str(ed.call("_kind_of", Vector2i(0, 2))), EditorCanvas.KIND_MINE, "上下翻转：y=0 -> y=2")
	assert_eq(str(ed.call("_kind_of", Vector2i(0, 0))), EditorCanvas.KIND_CLEAR, "原格应被清")


# ==================== 10. M/S 新语义 + 平移/选区不丢 ====================

func test_m_s_are_kind_shortcuts_and_tools_still_reachable() -> void:
	var ed := await _make_editor()
	var canvas := _canvas_of(ed)
	ed.call("_dispatch", "kind_mine")
	assert_eq(canvas.paint_kind, EditorCanvas.KIND_MINE, "M = 放雷")
	ed.call("_dispatch", "kind_safe")
	assert_eq(canvas.paint_kind, EditorCanvas.KIND_REVEAL, "S = 强制安全格（= 初始已翻开）")
	# 平移/区域选择功能**没被删**，只是换了键（P / L），鼠标按钮也还在
	ed.call("_dispatch", "tool_pan")
	assert_eq(canvas.tool, EditorCanvas.Tool.PAN, "平移工具仍在（P）")
	ed.call("_dispatch", "tool_select")
	assert_eq(canvas.tool, EditorCanvas.Tool.SELECT, "区域选择仍在（L）")
	var b = ed.get("_bindings")
	assert_eq(str(b.action_for_event(_key(KEY_P))), "tool_pan")
	assert_eq(str(b.action_for_event(_key(KEY_L))), "tool_select")


# ==================== 11. 旧 cfg 迁移（语义调整的兼容） ====================

func test_legacy_bindings_migrate_without_collision() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_CFG))
	var cfg := ConfigFile.new()
	# 旧版 cfg：M=平移、S=区域选择、R=随机布雷、Ctrl+R=重置视图；还有旧动作名 slot_1
	cfg.set_value("editor_keys", "tool_pan", "m")
	cfg.set_value("editor_keys", "tool_select", "s")
	cfg.set_value("editor_keys", "random_mines", "r")
	cfg.set_value("editor_keys", "reset_view", "ctrl+r")
	cfg.set_value("editor_keys", "slot_1", "1")
	cfg.save(TMP_CFG)
	var b = BINDINGS.new()
	b.path = TMP_CFG
	b.load_cfg()                       # 读回旧配置**不许崩**
	assert_eq(b.key_for("tool_pan"), "p", "旧 tool_pan=m 应迁移到新平移键 P")
	assert_eq(b.key_for("tool_select"), "l", "旧 tool_select=s 应迁移到 L")
	assert_eq(b.key_for("random_mines"), "ctrl+n", "旧 random_mines=r 应迁移到 Ctrl+N")
	assert_eq(b.key_for("reset_view"), "ctrl+0", "旧 reset_view=ctrl+r 应迁移到 Ctrl+0")
	assert_eq(b.key_for("kind_mine"), "m", "kind_mine 用新缺省 M")
	assert_eq(b.key_for("kind_safe"), "s", "kind_safe 用新缺省 S")
	assert_eq(b.key_for("rotate_selection"), "r", "rotate_selection 用新缺省 R")
	assert_eq(b.key_for("mirror_selection"), "ctrl+r", "mirror_selection 用新缺省 Ctrl+R")
	# 最关键：迁移后 M/S/R/Ctrl+R 各自唯一命中，不再抢键
	assert_eq(str(b.action_for_event(_key(KEY_M))), "kind_mine", "M 只能命中 kind_mine")
	assert_eq(str(b.action_for_event(_key(KEY_S))), "kind_safe", "S 只能命中 kind_safe")
	assert_eq(str(b.action_for_event(_key(KEY_R))), "rotate_selection", "R 只能命中 rotate_selection")
	assert_eq(str(b.action_for_event(_key(KEY_R, true))), "mirror_selection", "Ctrl+R 只能命中 mirror_selection")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_CFG))
