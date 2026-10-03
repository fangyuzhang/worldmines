# test_editor_perf_template_wiring.gd —— 编辑器「PerfLedger 接线 + TemplateLibrary 入口」接线自证
#
# 两个 core 模块（core/perf_ledger.gd、core/template_library.gd）各自已被单测验收，
# 缺的只是"接进编辑器、用户点得到"。所以本用例**只钉接线**，不重测算法：
#   A. PerfLedger：
#      ① verify / autosave / stats 真的上报了实测耗时（未上报 = -1，不假装 0）；
#      ② 自动保存空闲间隔 = AUTOSAVE_IDLE_MS ÷ rate_of("autosave")（延后保存 ⇒ 1200→4800ms）；
#      ③ 降级/回爬真的驱动热力图显隐；**用户开关与降级档分开**（用户手动关掉后恢复不许私自打开）；
#      ④ 既有热力图开关仍能开/关（回归）；
#      ⑤ 帧预算必须是一个**显式命名**的常量（不许在 _process 里内联猜数）。
#   B. TemplateLibrary：
#      ⑥ 选中模板 ⇒ 应用后文档尺寸/形状/雷位与模板一致（含形状盘判界走 grid().in_board()）；
#      ⑦ 超预算模板被既有 `_budget_allows` 闸门拦下，且给可读提示（绝不静默）。
#
# 类型纪律：编辑器脚本没有 `class_name` ⇒ 变量声明成 Object 并用 `.call()`；
# 【2026-10-03 重构后】热力图叠加层改走画布正式 API（set_overlay / set_overlay_visible）⇒
# 断言画布上的层（`canvas.has_overlay` / `opts.visible`），不再读编辑器内层类 `_hot_overlay`。
extends GutTest

const PerfLedgerScript := preload("res://core/perf_ledger.gd")
const TemplateLibraryScript := preload("res://core/template_library.gd")
const EditorVerifyScript := preload("res://core/editor_verify.gd")
## 只在测试里用来算"当前盘面**应该**得到的热力图"，与编辑器内那份同源，便于比对是否过期。
const HotMapScript := preload("res://core/hotmap.gd")
## 名字不能叫 `EditorScript`：那是引擎自带的原生类，会触发 "shadows a native class" 解析错误。
const EditorGDScript := preload("res://ui/level_editor.gd")

## 测试专用极小预算：只要上报的耗时 > 它就算超载；**故意不用真机帧预算常量**，
## 免得测试结果绑死在一个"待标定"的占位值上（那只由第 ⑤ 条单独钉住）。
const TEST_BUDGET := 1.0


func _make_editor() -> Object:
	var scene: PackedScene = load("res://ui/level_editor.tscn")
	assert_not_null(scene, "编辑器场景应能加载")
	var ed: Object = scene.instantiate()
	add_child_autofree(ed as Node)
	await wait_process_frames(2)
	# 关掉 _process：本用例要**用假时钟自己驱动**账本，避免节点自身的 _process 用真实时间戳插队。
	(ed as Node).set_process(false)
	return ed


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


## 4x4 单雷 (3,3) + 只翻开 (0,0)：与 `_deducible()` 是**不同盘面**，但同样可序贯演绎（用于"改盘防过期"）。
func _deducible4() -> EditorDoc:
	var d := EditorDoc.new(4, 4)
	d.mines.append(Vector2i(3, 3))
	d.revealed[Vector2i(0, 0)] = null
	return d


func _doc5() -> EditorDoc:
	var d := EditorDoc.new(5, 5)
	for m in [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)]:
		d.mines.append(m)
	d.revealed[Vector2i(4, 4)] = null
	return d


func _canvas_of(ed: Object) -> EditorCanvas:
	var found := (ed as Node).find_children("*", "EditorCanvas", true, false)
	return found[0] as EditorCanvas if not found.is_empty() else null


## 叠加层"是否可见"：画布正式 API 把每层的可见性放在 `opts.visible`（缺省 true）。
func _overlay_visible(canvas: EditorCanvas, name: String) -> bool:
	var layer: Dictionary = canvas.get_overlay(name)
	if layer.is_empty():
		return false
	return bool((layer.get("opts", {}) as Dictionary).get("visible", true))


## 读最后一条 toast 的文字（提示不堆叠，所以最多只有一条）。
func _last_toast(ed: Node) -> String:
	for c in ed.get_children():
		if c.has_meta("ui_toast"):
			return str((c as Label).text)
	return ""


## 如实上报超载 + 用假时钟走满进入窗口，把账本压到第 1 档（关热力图），再把动作落到界面。
## 返回 {perf, acts, at}；`at` = 降级发生的（假）时刻，供回爬驱动接续。
func _force_degrade_to_hotmap_off(ed: Object) -> Dictionary:
	var perf = ed.get("_perf")
	perf.report_ms(PerfLedgerScript.JOB_VERIFY, 100_000.0)
	perf.report_ms(PerfLedgerScript.JOB_AUTOSAVE, 0.0)
	perf.report_ms(PerfLedgerScript.JOB_STATS, 0.0)
	var base: int = int(perf.get("_now_ms")) + 10       # 保证时间戳单调（否则会被当成时钟回拨）
	perf.tick_measured(base, TEST_BUDGET)                # 起进入窗（本帧不动作）
	var at := base + PerfLedgerScript.DEFAULT_ENTER_MS
	var acts: Array = perf.tick_measured(at, TEST_BUDGET)
	ed.call("_apply_perf_actions", acts)
	return {"perf": perf, "acts": acts, "at": at}


## 从降级态走满退出窗口回到全开（先让预算达标，再等满 exit 窗口）。返回回爬动作。
func _force_restore_to_full(ed: Object, at: int) -> Array:
	var perf = ed.get("_perf")
	perf.report_ms(PerfLedgerScript.JOB_VERIFY, 0.0)
	var ok_at := at + 1
	perf.tick_measured(ok_at, TEST_BUDGET)               # 起退出窗
	var restore_at := ok_at + PerfLedgerScript.DEFAULT_EXIT_MS
	var acts: Array = perf.tick_measured(restore_at, TEST_BUDGET)
	ed.call("_apply_perf_actions", acts)
	return acts


# ==================== A⑤ 帧预算是有出处的显式常量 ====================

func test_frame_budget_is_an_explicit_constant_with_a_documented_source() -> void:
	# 能按名字取到这个常量，就证明它是显式命名的（不许在 _process 里内联一个猜出来的数）。
	assert_eq(int(EditorGDScript.PERF_FRAME_BUDGET_MS), int(EditorVerifyScript.DEFAULT_TOTAL_BUDGET_MS),
		"占位帧预算应与它的出处（验证总预算 8s）一致，便于真机标定后替换")


# ==================== A① 上报实测耗时 ====================

func test_verify_stats_and_autosave_report_measured_ms() -> void:
	var ed := await _make_editor()
	_bind(ed, _deducible())
	var perf = ed.get("_perf")
	assert_not_null(perf, "编辑器应持有一个 PerfLedger 实例")
	assert_almost_eq(perf.last_ms(PerfLedgerScript.JOB_VERIFY), -1.0, 0.001,
		"还没验证 ⇒ 未上报（-1，不假装是 0）")

	ed.call("_run_verify")
	assert_true(perf.last_ms(PerfLedgerScript.JOB_VERIFY) >= 0.0, "验证后应上报实测耗时")
	assert_true(perf.last_ms(PerfLedgerScript.JOB_STATS) >= 0.0, "统计行刷新也应上报耗时")

	ed.call("_write_autosave")
	assert_true(perf.last_ms(PerfLedgerScript.JOB_AUTOSAVE) >= 0.0, "自动保存后应上报实测耗时")


# ==================== A② 自动保存空闲间隔按频率缩放 ====================

func test_autosave_idle_scales_with_rate() -> void:
	var ed := await _make_editor()
	var perf = ed.get("_perf")
	assert_almost_eq(perf.rate_of(PerfLedgerScript.JOB_AUTOSAVE), 1.0, 0.001, "默认应是原频率")
	assert_eq(int(ed.call("_autosave_idle_ms")), 1200, "原频率下空闲间隔 = AUTOSAVE_IDLE_MS(1200)")
	perf.apply_action(PerfLedgerScript.ACT_DELAY_AUTOSAVE)
	assert_almost_eq(perf.rate_of(PerfLedgerScript.JOB_AUTOSAVE),
		PerfLedgerScript.DELAYED_AUTOSAVE_RATE, 0.001, "「延后自动保存」应把频率系数降下来")
	assert_eq(int(ed.call("_autosave_idle_ms")), 4800,
		"延后保存 ⇒ 1200 / 0.25 = 4800ms（落盘推迟，内存里的文档不丢）")


# ==================== A③ 降级/回爬联动热力图 + 用户开关与降级档分开 ====================

func test_degrade_hides_hotmap_and_recovery_restores_when_user_wants_it() -> void:
	var ed := await _make_editor()
	_bind(ed, _deducible())
	ed.call("_toggle_hotmap")
	var canvas := _canvas_of(ed)
	assert_true(bool(ed.get("_hotmap_on")), "用户已打开热力图")
	assert_true(_overlay_visible(canvas, "hotmap"), "打开后应可见")

	var d := _force_degrade_to_hotmap_off(ed)
	assert_true((d["acts"] as Array).has(PerfLedgerScript.ACT_DISABLE_HOTMAP),
		"超载应触发降级第①步（关热力图）：%s" % str(d["acts"]))
	assert_false(_overlay_visible(canvas, "hotmap"), "进入降级档 ⇒ 热力图必须真的不可见")
	assert_false(bool(d["perf"].is_enabled("hotmap")), "降级档这一侧应关掉 hotmap")
	assert_true(bool(ed.get("_hotmap_on")), "降级只压降级档，不该改用户意图")

	var back := _force_restore_to_full(ed, int(d["at"]))
	assert_true(back.has(PerfLedgerScript.ACT_RESTORE_HOTMAP),
		"负载回落应回爬最后一步（重开热力图）：%s" % str(back))
	assert_true(_overlay_visible(canvas, "hotmap"), "用户本想看 ⇒ 回落后应恢复可见")


func test_recovery_never_reopens_a_hotmap_the_user_turned_off() -> void:
	var ed := await _make_editor()
	_bind(ed, _deducible())
	ed.call("_toggle_hotmap")     # 开
	ed.call("_toggle_hotmap")     # 用户手动关
	var canvas := _canvas_of(ed)
	assert_false(bool(ed.get("_hotmap_on")), "用户已手动关闭")
	assert_false(_overlay_visible(canvas, "hotmap"), "关掉后不可见")

	var d := _force_degrade_to_hotmap_off(ed)
	assert_false(bool(d["perf"].is_enabled("hotmap")), "降级档应关掉 hotmap")
	var back := _force_restore_to_full(ed, int(d["at"]))
	assert_true(back.has(PerfLedgerScript.ACT_RESTORE_HOTMAP), "降级档这一侧确实重开了 hotmap")
	assert_true(bool(d["perf"].is_enabled("hotmap")), "该侧已恢复为开（restore_* 无条件打开）")
	assert_false(bool(ed.get("_hotmap_on")), "但用户意图仍是关（两者分开、互不装作一致）")
	assert_false(_overlay_visible(canvas, "hotmap"),
		"降级恢复**不许**把用户手动关掉的热力图私自打开")


# ==================== A③b 回爬恢复：数据在 ⇒ 不重跑；盘面改过 ⇒ 重算（绝不过期） ====================

func test_recovery_reuses_kept_data_without_rerunning_the_solver() -> void:
	var ed := await _make_editor()
	_bind(ed, _deducible())
	ed.call("_toggle_hotmap")
	var canvas := _canvas_of(ed)
	var builds := int(ed.get("_hotmap_builds"))
	assert_gt(builds, 0, "打开热力图应把求解器跑起来")
	assert_gt((canvas.get_overlay("hotmap").get("cells", {}) as Dictionary).size(), 0,
		"打开后应真的有格数据")

	var d := _force_degrade_to_hotmap_off(ed)
	assert_false(_overlay_visible(canvas, "hotmap"), "降级后应不可见")
	assert_true(canvas.has_overlay("hotmap"), "降级只是隐藏，数据应保留")
	assert_eq(int(ed.get("_hotmap_builds")), builds, "降级只翻可见性，不该重跑求解器")

	_force_restore_to_full(ed, int(d["at"]))
	assert_true(_overlay_visible(canvas, "hotmap"), "数据还在 ⇒ 回落后应恢复可见")
	assert_eq(int(ed.get("_hotmap_builds")), builds,
		"数据还在 ⇒ 恢复只恢复可见，**不重跑**求解器")


func test_recovery_after_a_board_edit_recomputes_and_never_shows_stale_data() -> void:
	var ed := await _make_editor()
	_bind(ed, _deducible())
	ed.call("_toggle_hotmap")
	var canvas := _canvas_of(ed)
	var builds := int(ed.get("_hotmap_builds"))

	var d := _force_degrade_to_hotmap_off(ed)
	assert_false(_overlay_visible(canvas, "hotmap"), "降级后应不可见")

	# 降级期间用户改了盘面：真实路径是 `_mark_dirty` → `_invalidate_derived_views`。
	# 前提：新盘面的热力图结果必须与旧盘不同，否则本用例防不住"显示过期结论"。
	var edited := _deducible4()
	var expect: Dictionary = HotMapScript.build(edited)["cells"]
	var old_expect: Dictionary = HotMapScript.build(_deducible())["cells"]
	assert_ne(expect, old_expect, "前提：这次改盘确实会改变热力图结果")

	ed.doc = edited
	ed.call("_mark_dirty")
	assert_false(canvas.has_overlay("hotmap"), "盘面一改，旧热力图数据必须立刻作废")
	assert_eq(int(ed.get("_hotmap_builds")), builds, "作废只是清掉，不该当场重算")

	_force_restore_to_full(ed, int(d["at"]))
	assert_true(_overlay_visible(canvas, "hotmap"), "用户本想看 ⇒ 回落后应恢复可见")
	assert_eq(int(ed.get("_hotmap_builds")), builds + 1,
		"数据已被作废 ⇒ 必须重算一次（绝不显示过期热力图）")
	var fresh: Dictionary = canvas.get_overlay("hotmap").get("cells", {}) as Dictionary
	assert_eq(fresh, expect, "恢复后显示的必须等于**当前盘面**算出来的结果（不是旧盘的）")


# ==================== A④ 既有热力图开关仍能开/关（回归） ====================

func test_existing_hotmap_toggle_still_works() -> void:
	var ed := await _make_editor()
	_bind(ed, _deducible())
	var btn := ed.get("_hotmap_btn") as Button
	var canvas := _canvas_of(ed)
	assert_not_null(btn, "左栏「显示」分组应有热力图开关")

	ed.call("_toggle_hotmap")
	assert_true(bool(ed.get("_hotmap_on")), "点一次应打开")
	assert_true(btn.button_pressed, "开着时按钮应处于按下态")
	assert_true(_overlay_visible(canvas, "hotmap"), "打开后叠加层应可见")

	ed.call("_toggle_hotmap")
	assert_false(bool(ed.get("_hotmap_on")), "再点一次应关闭")
	assert_false(btn.button_pressed, "关掉后按钮应弹起")
	assert_false(_overlay_visible(canvas, "hotmap"), "关掉后叠加层不可见")


# ==================== B⑥ 模板应用后文档与模板一致 ====================

func test_selected_template_applies_and_matches_the_library() -> void:
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var opt := ed.get("_template_opt") as OptionButton
	var note := ed.get("_template_note") as Label
	assert_not_null(opt, "左栏应有模板下拉（模板库入口）")
	assert_not_null(note, "应有模板说明/提示行")

	var idx := -1
	for i in opt.item_count:
		if str(opt.get_item_metadata(i)) == "official_moat":
			idx = i
	assert_true(idx >= 0, "模板库应含 official_moat（护城河）")
	opt.selected = idx
	opt.item_selected.emit(idx)
	assert_true(note.text.find("护城河") != -1, "选中模板应显示它的说明：%s" % note.text)

	ed.call("_apply_selected_template")

	var expect: EditorDoc = TemplateLibraryScript.build_doc("official_moat")
	var doc: EditorDoc = ed.doc
	assert_eq(doc.rows, expect.rows, "行数应与模板一致")
	assert_eq(doc.cols, expect.cols, "列数应与模板一致")
	assert_eq(doc.shape_kind, expect.shape_kind, "形状族应与模板一致")
	assert_eq(doc.mine_count(), expect.mine_count(), "雷位数应与模板一致")
	assert_eq(doc.revealed.size(), expect.revealed.size(), "初始翻开格数应与模板一致")
	# 形状盘判界一律问 grid().in_board()：护城河中心是洞、外圈仍在盘上。
	assert_false(doc.grid().in_board(Vector2i(3, 3)), "护城河中心应是洞（不在盘上）")
	assert_true(doc.grid().in_board(Vector2i(0, 0)), "护城河外圈仍是盘上格")
	assert_true(note.text.find("已应用") != -1, "应用后应有可读反馈：%s" % note.text)


# ==================== B⑦ 超预算模板被拦且有提示 ====================

func test_over_budget_template_is_blocked_with_readable_hints() -> void:
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var note := ed.get("_template_note") as Label
	var before_rows: int = ed.doc.rows
	var before_cols: int = ed.doc.cols
	var before_mines: int = ed.doc.mine_count()

	# 71×71 = 5041 > EditorDoc.MAX_CELL_BUDGET(5000) ⇒ 必须走既有 `_budget_allows` 被拦。
	var build := {
		"title": "超大", "rows": 71, "cols": 71,
		"shape_kind": "", "shape_params": {},
		"mines": [Vector2i(0, 0)], "obstacles": [], "revealed": {},
	}
	var applied: bool = ed.call("_apply_template_build", build, "超大测试模板")
	assert_false(applied, "超预算模板不许应用")
	assert_eq(ed.doc.rows, before_rows, "被拦时文档行数不许变")
	assert_eq(ed.doc.cols, before_cols, "被拦时文档列数不许变")
	assert_eq(ed.doc.mine_count(), before_mines, "被拦时雷位不许变")
	assert_true(note.text.find("预算") != -1, "要有可读的常驻提示（不许静默）：%s" % note.text)
	var toast := _last_toast(ed)
	assert_true(toast.find("上限") != -1 or toast.find("预算") != -1,
		"要有可读 toast 说明为什么被拦：%s" % toast)
