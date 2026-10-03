# test_editor_hotmap_replay_wiring.gd —— 热力图 / 推理链回放**接线**自证（HotMap + ReplayModel → 编辑器 UI）
#
# 两个核心模块（core/hotmap.gd、core/replay_model.gd）早已交付并被各自单测验收，
# 缺的只是"用户点不到"。所以本用例**只钉接线**，不重测算法：
#   1) 热力图开关能开/关：开 ⇒ 画布叠加层拿到格数据且可见；关 ⇒ 只隐藏、数据保留（见 1b）；
#   2) HotMap 返回 ok=false（矛盾盘 / 超格数上限）⇒ 界面必须有**可读提示**（绝不静默）；
#   3) 回放虚拟化：列表总高 = 步数 × 行高，但滚动到中部时只实例化视口内的行（远小于总步数）；
#   4) 点回放某行 ⇒ 视口定位到该步 `cells[0]`（复用问题面板同一套 `_focus_cell` 换算）；
#   5) 试玩态热力图强制不可见（唯一判据 `EditorViewState.is_cheat_visible()`，编辑器不许自判）；
#   6) 截断日志 ⇒ 顶部 banner 如实透出（截断原因 / 丢弃步数）。
#
# 类型纪律：编辑器脚本没有 `class_name` ⇒ 变量声明成 Object 并用 `.call()`；
# 【2026-10-03 重构后】热力图叠加层已改走画布正式 API（`ui/editor_canvas.gd` 的
# set_overlay / set_overlay_visible / clear_overlay）⇒ 断言画布上的层，不再读编辑器内层类。
extends GutTest

const VIEW_STATE := preload("res://core/editor_view_state.gd")
const ROW_H := 22.0      # 与 `level_editor.gd` 的 `_replay_row_h` 同值
const VIEW_H := 150.0


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


## 叠加层"是否可见"：画布正式 API 把每层的可见性放在 `opts.visible`（缺省 true，见 `_draw_overlays`）。
func _overlay_visible(canvas: EditorCanvas, name: String) -> bool:
	var layer: Dictionary = canvas.get_overlay(name)
	if layer.is_empty():
		return false
	return bool((layer.get("opts", {}) as Dictionary).get("visible", true))


func _bind(ed: Object, d: EditorDoc) -> void:
	ed.doc = d
	ed.call("_doc_to_ui")
	ed.call("_refresh_all")


## 3x3 单雷 (2,2) + 只翻开 (0,0)：可序贯演绎 ⇒ HotMap.build 必成功（快、确定性）。
func _deducible() -> EditorDoc:
	var d := EditorDoc.new(3, 3)
	d.mines.append(Vector2i(2, 2))
	d.revealed[Vector2i(0, 0)] = null
	return d


## 5x5 两雷 + 全部安全格翻开 + 声明 5 雷（隐藏格只剩 2）⇒ verify 报"矛盾"⇒ HotMap.build 必 ok=false。
func _contradiction() -> EditorDoc:
	var d := EditorDoc.new(5, 5)
	d.mines.append(Vector2i(0, 0))
	d.mines.append(Vector2i(4, 4))
	for y in d.rows:
		for x in d.cols:
			var p := Vector2i(x, y)
			if not d.mines.has(p):
				d.revealed[p] = null
	d.declared_total_mines = 5
	return d


func _doc5() -> EditorDoc:
	var d := EditorDoc.new(5, 5)
	for m in [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)]:
		d.mines.append(m)
	d.revealed[Vector2i(4, 4)] = null
	return d


## n 步的假日志（步骤内容不重要：窗口计算只看条数；描述按 pos/state/method 拼）。
func _steps(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append({"pos": [i % 5, int(i / 5.0)], "state": "safe", "method": "enumeration",
			"rule": "classic", "proof": "测试步", "sources": []})
	return out


# ==================== 1. 开关：能开能关 + 关掉只隐藏 ====================
#
# 【改动原因】旧实现是"运行期子节点"（`_hot_overlay`），关掉即把 cells 清空。
# 重构后热力图改走画布正式叠加层 API ⇒ 断言对象从"子节点"换成 `canvas.has_overlay("hotmap")`；
# 且按 `set_overlay_visible` 的契约，关掉**只隐藏、不丢数据**（数据保留 = 再打开无需重跑求解器）。

func test_hotmap_toggle_applies_and_then_hides_the_overlay() -> void:
	var ed := await _make_editor()
	_bind(ed, _deducible())
	var btn := ed.get("_hotmap_btn") as Button
	var canvas := _canvas_of(ed)
	assert_not_null(btn, "左栏「显示」分组应有热力图开关")
	assert_not_null(canvas, "编辑器内应有画布")

	assert_false(bool(ed.get("_hotmap_on")), "默认应是关的")
	assert_false(canvas.has_overlay("hotmap"), "关着时画布上不该有 hotmap 叠加层")

	ed.call("_toggle_hotmap")
	assert_true(bool(ed.get("_hotmap_on")), "点一次应打开")
	assert_true(btn.button_pressed, "开着时按钮应处于按下态")
	assert_true(canvas.has_overlay("hotmap"), "打开后应把 HotMap.build 的格数据交给画布叠加层")
	assert_gt((canvas.get_overlay("hotmap").get("cells", {}) as Dictionary).size(), 0,
		"叠加层应拿到格数据")
	assert_true(_overlay_visible(canvas, "hotmap"), "编辑态打开后叠加层应可见")

	ed.call("_toggle_hotmap")
	assert_false(bool(ed.get("_hotmap_on")), "再点一次应关闭")
	assert_false(btn.button_pressed, "关掉后按钮应弹起")
	assert_false(_overlay_visible(canvas, "hotmap"), "关掉后叠加层不可见")
	assert_true(canvas.has_overlay("hotmap"), "关掉只隐藏、层还在（数据保留，见 1b）")


# ==================== 1b. 关掉只隐藏、不丢数据 ⇒ 不必重跑求解器 ====================

func test_turning_hotmap_off_keeps_the_overlay_data() -> void:
	var ed := await _make_editor()
	_bind(ed, _deducible())
	var canvas := _canvas_of(ed)
	assert_not_null(canvas, "编辑器内应有画布")

	ed.call("_toggle_hotmap")
	var cells: Dictionary = canvas.get_overlay("hotmap").get("cells", {}) as Dictionary
	assert_gt(cells.size(), 0, "打开后应有热力图格数据")

	ed.call("_toggle_hotmap")
	assert_false(_overlay_visible(canvas, "hotmap"), "关掉后不可见")
	assert_true(canvas.has_overlay("hotmap"),
		"关掉热力图后该层仍在（只隐藏不丢数据 ⇒ 不用重跑求解器）")
	assert_eq((canvas.get_overlay("hotmap").get("cells", {}) as Dictionary).size(), cells.size(),
		"关掉后格数据必须原样保留（旧的「清空」实现已被 set_overlay_visible 取代）")


# ==================== 2. ok=false / 超上限 ⇒ 可读提示（不许静默） ====================

func test_hotmap_refusal_and_oversize_both_surface_a_readable_hint() -> void:
	var ed := await _make_editor()
	var note := ed.get("_hotmap_note") as Label
	var canvas := _canvas_of(ed)
	assert_not_null(note, "应有热力图说明标签（提示的落点）")
	assert_not_null(canvas, "编辑器内应有画布")

	# ① HotMap 因"矛盾"拒绝：必须有可读提示，且不许把半截数据涂上去。
	_bind(ed, _contradiction())
	ed.call("_toggle_hotmap")
	assert_true(note.visible, "ok=false 时必须给出可读提示（不许静默什么都不发生）")
	assert_true(note.text.find("热力图不可用") != -1, "提示要说清是「不可用」：%s" % note.text)
	assert_true(note.text.find("矛盾") != -1, "提示要带上 HotMap 的 reason：%s" % note.text)
	assert_false(canvas.has_overlay("hotmap"),
		"拒绝时不许涂半截数据（旧断言查子节点 cells；现查画布上没有该层）")

	# ② 超格数上限：HotMap 自己的护栏给出 reason，UI 只负责把 reason 说出来（按 reason 提示）。
	#    71×71 = 5041 > EditorDoc.MAX_CELL_BUDGET(5000)；`cell_count()` 是纯整数运算 ⇒ 立刻拒绝。
	ed.doc = EditorDoc.new(71, 71)
	ed.call("_refresh_hotmap")
	assert_true(note.visible, "超上限时也要有提示")
	assert_true(note.text.find("上限") != -1, "提示要按 reason 说明超限：%s" % note.text)
	assert_false(canvas.has_overlay("hotmap"), "超限时不许涂任何格")


# ==================== 3. 回放虚拟化：只实例化视口内的行 ====================

func test_replay_list_virtualizes_to_the_visible_rows_only() -> void:
	var ed := await _make_editor()
	var scroll := ed.get("_replay_scroll") as ScrollContainer
	var rows := ed.get("_replay_rows") as Control
	assert_not_null(scroll, "应有回放列表滚动容器")
	assert_not_null(rows, "应有回放行容器")
	assert_gt(scroll.get_v_scroll_bar().value_changed.get_connections().size(), 0,
		"滚动条必须接上「重建可见行」（否则滚动就露白 / 一次性建满）")

	ed.call("_set_replay_log", {"steps": _steps(500)})
	assert_eq(int(ed.get("_replay_model").step_count()), 500, "应载入 500 步")
	assert_almost_eq(rows.custom_minimum_size.y, 500.0 * ROW_H, 0.5,
		"列表总高必须是 步数 × 行高（滚动范围要对）")

	ed.call("_rebuild_replay_rows", 0.0, VIEW_H)
	var top := rows.get_child_count()
	assert_gt(top, 0, "顶部应实例化可见的那几行")

	ed.call("_rebuild_replay_rows", 5000.0, VIEW_H)      # 中部（第 ~227 行开外）
	var mid := rows.get_child_count()
	assert_lt(mid, 60, "中部只应实例化视口内的行，远小于总步数 500（实际 %d）" % mid)
	assert_gt(mid, 0, "中部也要有行（不能整段空白）")

	# 区间长度必须与 ReplayModel 的窗口计算一致（overscan 与实现同值 2）。
	var win: Dictionary = ed.get("_replay_model").visible_range(5000.0, VIEW_H, ROW_H, 2)
	var expect := int(win["last"]) - int(win["first"]) + 1
	assert_eq(mid, expect, "实例化行数应恰好等于 visible_range 给出的区间长度")


# ==================== 4. 点行 ⇒ 定位到 cells[0] ====================

func test_replay_row_click_focuses_the_conclusion_cell() -> void:
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var canvas := _canvas_of(ed)
	canvas.size = Vector2(600, 600)
	var target := Vector2i(4, 1)
	ed.call("_set_replay_log", {"steps": [
		{"pos": [target.x, target.y], "state": "mine", "method": "enumeration",
			"rule": "classic", "proof": "测试步", "sources": [[0, 0]]}]})

	var scroll := ed.get("_replay_scroll") as ScrollContainer
	var rows := ed.get("_replay_rows") as Control
	scroll.size = Vector2(300, VIEW_H)
	ed.call("_rebuild_replay_rows", 0.0, VIEW_H)
	assert_eq(rows.get_child_count(), 1, "1 步日志应实例化 1 行")
	var row := rows.get_child(0) as Button
	assert_not_null(row, "回放行应是可点按钮")
	row.pressed.emit()                                   # 走真实点击路径（信号 ⇒ _focus_cell）

	var c := canvas.cell_rect(target).get_center()
	assert_almost_eq(c.x, canvas.size.x * 0.5, 1.0, "点行后结论格应水平居中（复用问题面板跳转）")
	assert_almost_eq(c.y, canvas.size.y * 0.5, 1.0, "点行后结论格应垂直居中")
	assert_gte(canvas.zoom, 1.5, "跳转应抬高缩放，让目标格看得清")


# ==================== 5. 试玩态：热力图强制不可见 ====================

func test_hotmap_is_forced_hidden_in_play_mode() -> void:
	var ed := await _make_editor()
	_bind(ed, _deducible())
	ed.call("_toggle_hotmap")
	var canvas := _canvas_of(ed)
	assert_true(_overlay_visible(canvas, "hotmap"), "编辑态打开后可见")
	var shown := (canvas.get_overlay("hotmap").get("cells", {}) as Dictionary).size()
	assert_gt(shown, 0, "编辑态应有格数据")

	var vs = ed.get("_view_state")
	vs.set_mode(VIEW_STATE.MODE_PLAY)                    # 与 `_enter_playtest` 同一条路径
	ed.call("_apply_cheat_visibility")
	assert_false(_overlay_visible(canvas, "hotmap"), "试玩态热力图强制不可见（唯一判据，不许自判）")
	assert_true(bool(ed.get("_hotmap_on")), "开关本身仍是开（只是被强制隐藏）")
	assert_eq((canvas.get_overlay("hotmap").get("cells", {}) as Dictionary).size(), shown,
		"强制隐藏只是不可见，数据不该被抹掉")

	vs.set_mode(VIEW_STATE.MODE_EDIT)
	ed.call("_apply_cheat_visibility")
	assert_true(_overlay_visible(canvas, "hotmap"), "回编辑态后按开关恢复可见")


# ==================== 6. 截断日志：顶部 banner 如实透出 ====================

func test_truncated_log_shows_a_banner_on_top() -> void:
	var ed := await _make_editor()
	var banner := ed.get("_replay_banner") as Label
	assert_not_null(banner, "应有截断 banner 标签")

	ed.call("_set_replay_log", {"steps": _steps(3)})
	assert_false(banner.visible, "未截断的日志不该显示 banner（不许无中生有）")

	ed.call("_set_replay_log", {"steps": _steps(3), "truncated": true,
		"kept_steps": 3, "dropped_steps": 4321, "truncated_reason": "字节上限 2MiB"})
	assert_true(banner.visible, "截断日志必须显示顶部 banner（不许把「只剩前 N 步」当完整链）")
	assert_true(banner.text.find("截断") != -1, "banner 要说清被截断：%s" % banner.text)
	assert_true(banner.text.find("4321") != -1, "banner 要写出丢弃的步数：%s" % banner.text)
	assert_true(banner.text.find("字节上限") != -1, "banner 要带上截断原因：%s" % banner.text)
