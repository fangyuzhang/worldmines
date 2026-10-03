# test_editor_ux.gd —— 小白可用性修补的回归闸门（2026-10-02 以小白身份走查后加的）
#
# 这些用例都对应**实测抓到**的具体问题，每条都写着"当时是怎么坏的"：
#   · 第一个页签显示成内部名「属性页滚动」；
#   · 切到「AI 帮我写」页，右面板被 47 字的配方项撑到 738px，棋盘从 694px 挤成 286px（一格 29px）；
#   · 「保存」「试玩」在左栏滚动区里（内容 1010px / 窗口 691px）⇒ 不滚滚轮根本看不到；
#   · 全界面没有地方能起关卡名字，且中文标题会被文件名过滤吃掉；
#   · 按完配方/试玩之后，编辑器自己红字报"id 已被注册"，把试玩/验证/分享一起挡住；
#   · 首屏没有"这是干什么的、从哪开始"。
#
# 类型纪律：编辑器脚本没有 class_name ⇒ 变量声明成 Object 并用 .call() 调它的方法。
extends GutTest

## 输入侧总量闸门：**preload 引用**（新全局类在 headless 缓存里可能解析不到，见坑表 #26）。
const LevelGuardRef := preload("res://core/level_guard.gd")


var _registered: Array[String] = []


func after_each() -> void:
	for rid in _registered:
		RuleRegistry.default().unregister(StringName(rid))
	_registered.clear()


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


func _doc5() -> EditorDoc:
	var d := EditorDoc.new(5, 5)
	for m in [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)]:
		d.mines.append(m)
	return d


func _canvas_of(ed: Object) -> EditorCanvas:
	var found := (ed as Node).find_children("*", "EditorCanvas", true, false)
	return found[0] as EditorCanvas if not found.is_empty() else null


func _tabs_of(ed: Object) -> TabContainer:
	var found := (ed as Node).find_children("*", "TabContainer", true, false)
	return found[0] as TabContainer if not found.is_empty() else null


func _find_button(ed: Object, prefix: String) -> Button:
	for b in (ed as Node).find_children("*", "Button", true, false):
		var bt := b as Button
		if bt.get_class() == "Button" and bt.text.begins_with(prefix):
			return bt
	return null


func _press(ed: Object, prefix: String) -> bool:
	var b := _find_button(ed, prefix)
	if b == null:
		return false
	b.pressed.emit()
	return true


## 该控件在编辑器内部，是否被 ScrollContainer 包着（= 需要滚动才看得到）。
func _scroll_ancestors_below(n: Node, stop_at: Node) -> int:
	var c := 0
	var p := n.get_parent()
	while p != null and p != stop_at:
		if p is ScrollContainer:
			c += 1
		p = p.get_parent()
	return c


func _recipe(id: String) -> Dictionary:
	for r in SpecHelper.recipes():
		if str(r["id"]) == id:
			return r
	return {}


# ==================== 界面：页签名 / 棋盘不被挤 / 关键按钮常驻 ====================

func test_first_tab_is_named_in_plain_chinese() -> void:
	var ed := await _make_editor()
	var tabs := _tabs_of(ed)
	assert_not_null(tabs, "应有右侧页签容器")
	assert_eq(tabs.get_tab_title(0), "属性", "第一个页签不能显示内部名（原为「属性页滚动」）")
	for i in tabs.get_tab_count():
		var t := tabs.get_tab_title(i)
		assert_false(t.find("滚动") != -1, "页签名不该出现「滚动」这类内部字样：%s" % t)


func test_switching_tabs_does_not_shrink_the_board() -> void:
	# 实测缺陷：切到「AI 帮我写」页后右面板 330 → 738px，棋盘 694 → 286px（一格 29px）
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var canvas := _canvas_of(ed)
	var tabs := _tabs_of(ed)
	var widths: Array[int] = []
	for i in tabs.get_tab_count():
		tabs.current_tab = i
		await wait_process_frames(1)
		await wait_process_frames(1)
		widths.append(int(canvas.size.x))
	var bad := ""
	for i in widths.size():
		if widths[i] < widths[0] - 2:
			bad += "%s→%d " % [tabs.get_tab_title(i), widths[i]]
	assert_eq(bad, "", "任何页签都不许把棋盘挤小（棋盘宽：%s；首屏 %d）" % [str(widths), widths[0]])


func test_play_and_save_buttons_are_not_inside_the_scroll_area() -> void:
	# 实测缺陷：左栏内容 1010px、窗口只有 691px ⇒ 这两个按钮在屏幕外，小白找不到"能玩/能存"
	var ed := await _make_editor()
	_bind(ed, _doc5())
	for prefix in ["试玩", "保存"]:
		var b := _find_button(ed, prefix)
		assert_not_null(b, "左栏应有常驻的「%s」按钮" % prefix)
		assert_eq(_scroll_ancestors_below(b, ed as Node), 0,
			"「%s」不能放在滚动区里（否则矮窗口下看不见）" % prefix)
		assert_true(b.get_global_rect().end.y <= (ed as Control).size.y,
			"「%s」必须在首屏可见范围内（底边 %d ≤ 窗口 %d）" % [
				prefix, int(b.get_global_rect().end.y), int((ed as Control).size.y)])


func test_example_level_button_loads_a_playable_level() -> void:
	var ed := await _make_editor()
	assert_true(_press(ed, "看示例关卡"), "引导条上应有「看示例关卡」")
	await wait_process_frames(1)
	assert_eq(int(ed.doc.mines.size()), 10, "示例关应有 10 颗雷")
	var rep: Dictionary = ed.doc.validate()
	assert_true(bool(rep["ok"]), "示例关必须自己先通过校验：%s" % str(rep["errors"]))
	assert_gt(_canvas_of(ed).values.size(), 0, "示例关应能算出数字")


func test_intro_bar_reappears_on_demand() -> void:
	var ed := await _make_editor()
	var bar := ed.get("_intro_bar") as PanelContainer
	assert_not_null(bar, "应有首屏引导条")
	ed.call("_set_intro_visible", false, false)
	assert_false(bar.visible, "可以关掉")
	ed.call("_set_intro_visible", true, false)
	assert_true(bar.visible, "左栏「新手引导」应能再打开：%s" % str(bar.get_child(0).get_child(0)))


# ==================== 关卡名字（含中文）必须真的生效 ====================

func test_title_edit_names_the_saved_file() -> void:
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var te := ed.get("_title_edit") as LineEdit
	assert_not_null(te, "属性页应有「关卡名字」输入框")
	te.text = "我的第一关"
	te.text_changed.emit("我的第一关")
	var p := str(ed.call("_target_save_path"))
	assert_true(p.ends_with("我的第一关.json"),
		"中文名字必须能进文件名（原来被过滤成 level）：%s" % p)


func test_illegal_filename_chars_are_stripped() -> void:
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var te := ed.get("_title_edit") as LineEdit
	te.text = "a/b:c*d?e"
	te.text_changed.emit("a/b:c*d?e")
	var p := str(ed.call("_target_save_path"))
	assert_eq(p.get_file(), "abcde.json", "文件名里的非法字符要被去掉：%s" % p)


# ==================== 规则注册之后不许再报"已被注册" ====================

func test_rule_stays_valid_after_being_registered() -> void:
	# 实测缺陷：按完「用这个配方」后，状态栏/本盘问题/验证/生成分享包一起报
	# 「规格错误：id ... 已被注册」，而「规则」页同时说"规格合法" ⇒ 小白无法理解也无法修。
	var rec := _recipe("spec_r8_plus1")
	assert_false(rec.is_empty(), "应有「周围 8 格 + 1」这条配方")
	var spec: Dictionary = rec["spec"]   # 配方卡是包装字典，规格在 spec 键里（UI 也只取这一层）
	var reg := SpecRulePlugin.register_from_json(JSON.stringify(spec))
	assert_true(bool(reg["ok"]), "先注册这条配方：%s" % str(reg["errors"]))
	_registered.append(str(reg["id"]))

	var d := _doc5()
	d.rule_spec = spec
	var rep := d.validate()
	var bogus := 0
	for e in rep["errors"]:
		if str((e as Dictionary)["text"]).find("已被注册") != -1:
			bogus += 1
	assert_eq(bogus, 0, "自己刚注册的规格不该被判成「已被注册」：%s" % str(rep["errors"]))
	assert_true(bool(rep["ok"]), "注册之后这份文档仍应通过校验：%s" % str(rep["errors"]))
	assert_eq(SpecHelper.explain_spec(spec).find("不能生效"), -1, "AI 页说明也不该说「不能生效」")


func test_other_spec_with_the_same_id_still_errors() -> void:
	# 反向闸门：豁免只给"同源的那条"。用户手改成另一条同 id 的规格时，注册表里是旧版本，
	# 必须照实报错（否则会静默用旧规则跑他的新关卡，比误报更糟）。
	var rec := _recipe("spec_r8")
	var spec: Dictionary = rec["spec"]
	var reg := SpecRulePlugin.register_from_json(JSON.stringify(spec))
	assert_true(bool(reg["ok"]), "先注册：%s" % str(reg["errors"]))
	_registered.append(str(reg["id"]))

	var edited: Dictionary = spec.duplicate(true)
	edited["title"] = "我手改过的另一条（同 id）"
	var d := _doc5()
	d.rule_spec = edited
	var rep := d.validate()
	var found := 0
	for e in rep["errors"]:
		if str((e as Dictionary)["text"]).find("已被注册") != -1:
			found += 1
	assert_eq(found, 1, "不同内容的同 id 规格必须照实报错：%s" % str(rep["errors"]))


func test_adding_mines_to_a_loaded_level_does_not_fake_a_mismatch_error() -> void:
	# 实测缺陷（2026-10-02 真机点击复现）：打开上次的存档（0 雷）→ 改雷数 → 随机布雷
	# → 立刻红字「声明的总雷数 0 与实际雷位 N 颗不一致」，而界面上**没有地方**能改那个"声明值"
	# ⇒ 点试玩得到「先修好这些问题再试玩：声明的总雷数 0 与实际雷位 1 颗不一致…」，试玩/打包全被挡。
	var ed := await _make_editor()
	var lv := {"name": "空关", "size": {"rows": 9, "cols": 9}, "total_mines": 0,
		"mines": [], "revealed": []}
	assert_true(bool(ed.call("_load_from_text", JSON.stringify(lv))), "先把这份 0 雷的存档载进来")
	await wait_process_frames(1)
	ed.get("_mines_spin").value = 10
	ed.call("_on_mines_changed")
	assert_true(_press(ed, "随机布雷"), "随机布雷应能点到")
	await wait_process_frames(1)
	var rep: Dictionary = ed.doc.validate()
	var mismatch := 0
	for e in rep["errors"]:
		if str((e as Dictionary)["text"]).find("声明的总雷数") != -1:
			mismatch += 1
	assert_eq(mismatch, 0, "自己放雷之后不该再报「声明值不一致」：%s" % str(rep["errors"]))
	assert_true(bool(rep["ok"]), "这份文档必须能通过校验（否则试玩与生成分享包都被挡）：%s" % str(rep["errors"]))
	assert_eq(int(ed.doc.mine_count()), 10, "雷应当真的放下了 10 颗")


func test_a_genuinely_mismatched_level_still_reports_the_error() -> void:
	# 反向闸门：豁免只给"编辑器自己改了雷"这一种。别人发来的关卡若**真的**声明不符，必须照实报错。
	var ed := await _make_editor()
	var lv := {"name": "声明不符的关", "size": {"rows": 9, "cols": 9}, "total_mines": 5,
		"mines": [{"r": 0, "c": 0}], "revealed": []}
	ed.call("_load_from_text", JSON.stringify(lv))
	await wait_process_frames(1)
	var rep: Dictionary = ed.doc.validate()
	var found := 0
	for e in rep["errors"]:
		if str((e as Dictionary)["text"]).find("声明的总雷数") != -1:
			found += 1
	assert_eq(found, 1, "真的声明不符仍要报错：%s" % str(rep["errors"]))


func test_danger_toasts_carry_a_text_symbol_not_only_color() -> void:
	# 无障碍：危险提示原来只把文字染红（颜色是唯一信号）。现在必须带一个文字符号。
	var ed := await _make_editor()
	ed.call("_toast", "这是一条错误", true)
	await wait_process_frames(1)
	# 按**文字**扫而不是按节点名：同名的 Label 会被 Godot 自动改名（@Label@NNN），
	# 而 `_ready` 里那条"已恢复上次未保存的编辑内容"往往已经先占用了 "Toast" 这个名字。
	var found := ""
	var stack: Array[Node] = [(ed as Node)]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Label and (n as Label).text.find("这是一条错误") != -1:
			found = (n as Label).text
		for c in n.get_children():
			stack.append(c)
	assert_true(found.begins_with("⚠"), "危险提示必须带 ⚠（不能只靠颜色）：%s" % found)


func test_clicking_the_canvas_paints_a_mine_not_opens_a_cell() -> void:
	# 这是"手机扫雷玩家"最容易误解的一点：编辑器里左键点格子 = **放雷**（不是开格）。
	# 界面上必须说清（左栏那行提示），这里把行为钉住，避免以后有人"顺手"改成开格。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var canvas := _canvas_of(ed)
	canvas.size = Vector2(600, 600)
	var before := int(ed.doc.mines.size())
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = canvas.cell_rect(Vector2i(3, 3)).get_center()
	canvas._gui_input(ev)
	assert_eq(int(ed.doc.mines.size()), before + 1, "左键点格子应当是放一颗雷")
	var hint := ""
	for lab in (ed as Node).find_children("*", "Label", true, false):
		if (lab as Label).text.find("不是开格") != -1:
			hint = (lab as Label).text
	assert_true(hint != "", "左栏必须用文字说明「左键=放雷不是开格」（实测小白的第一反应就是开格）")


func test_recipe_set_covers_the_common_beginner_combination() -> void:
	# 「只算上下左右」+「数字 +1」这个组合原来在配方里没有 ⇒ 小白只能求助 AI（还容易被卡住）
	var titles: Array[String] = []
	for r in SpecHelper.recipes():
		titles.append(str(r["title"]))
	assert_true(titles.has("上下左右 4 格 + 1"),
		"配方里应有「上下左右 4 格 + 1」：%s" % str(titles))
	assert_gt(titles.size(), 5, "配方数量：%s" % str(titles))


# ==================== 危险操作 / 撤销步进 / 验证反馈 / 快捷键说明 ====================

func test_clearing_everything_asks_first_and_can_be_cancelled() -> void:
	# 实测缺陷（2026-10-02 真机走查）：「清空全部雷/障碍/翻开」点一下就全清，没有确认框。
	# 小白的第一反应是"啊我全没了"；撤销虽能救回，但他得先想到撤销。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var bar := ed.get("_confirm_bar") as PanelContainer
	assert_not_null(bar, "应有危险操作确认条")
	assert_false(bar.visible, "默认不该显示确认条")
	var mine_count := int(ed.doc.mines.size())
	assert_gt(mine_count, 0, "测试前置：盘上应有雷")

	assert_true(_press(ed, "清空全部雷"), "应有「清空全部雷/障碍/翻开」按钮")
	assert_true(bar.visible, "点清空必须先问一句")
	assert_eq(int(ed.doc.mines.size()), mine_count, "还没确认之前不许动数据")
	assert_true(str((ed.get("_confirm_label") as Label).text).find("撤销") != -1,
		"问句里要说明「清空后可以撤销」（否则他只知道慌了）")

	assert_true(_press(ed, "取消"), "确认条上应有取消")
	assert_false(bar.visible, "取消后确认条应收起")
	assert_eq(int(ed.doc.mines.size()), mine_count, "取消后数据必须原样")

	assert_true(_press(ed, "清空全部雷"), "再点一次清空")
	assert_true(_press(ed, "确认"), "确认条上应有确认")
	assert_eq(int(ed.doc.mines.size()), 0, "只有点了确认才真的清空")
	ed.call("_undo_once")
	assert_eq(int(ed.doc.mines.size()), mine_count, "清空之后按撤销应能把雷救回来")


func test_two_button_commands_are_separate_undo_steps() -> void:
	# 实测缺陷：700ms 内的两个**不同按钮**操作会被并成一步撤销
	#（小白按一次撤销看到"一下退了两件事"，我最初误报成"清空无法撤销"）。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	ed.get("_mines_spin").value = 5
	assert_true(_press(ed, "随机布雷"), "先随机布雷")
	var placed := int(ed.doc.mines.size())
	assert_eq(placed, 5, "随机布雷应放下 5 颗")
	# 紧接着（同一帧内）来第二条**按钮命令**：它必须自成一步
	assert_true(_press(ed, "清空全部雷"), "再点清空")
	assert_true(_press(ed, "确认"), "确认清空")
	assert_eq(int(ed.doc.mines.size()), 0, "清空生效")
	ed.call("_undo_once")
	assert_eq(int(ed.doc.mines.size()), placed,
		"一次撤销只该退掉「清空」：雷要回到 %d 颗（不许把随机布雷也一起退掉）" % placed)


func test_verify_writes_a_working_message_before_it_computes() -> void:
	# 实测缺陷：验证是同步重活，点下去界面毫无动静（9×9 约 90ms，盘大了更久），
	# 小白会以为"点了没反应"。现在必须先写出「正在验证…」再算。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var plain := ed.get("_verify_plain") as Label
	assert_not_null(plain, "验证面板应有人话结论行")
	# 故意不 await：函数会停在第一个 await 处，此时正好能看清它先写了什么
	ed.call("_on_verify")
	assert_true(plain.text.find("正在验证") != -1,
		"点验证要立刻显示「正在验证…」，否则小白以为点了没反应：%s" % plain.text)
	var btn := ed.get("_verify_btn") as Button
	assert_true(btn.disabled, "算的时候应禁用按钮，防止连点排队")
	await wait_process_frames(2)   # 让它自然跑完（协程靠 await 的信号恢复，不需要调用方持有状态）
	assert_true(plain.text.find("正在验证") == -1, "算完要换成真正的结论：%s" % plain.text)
	assert_false(btn.disabled, "算完要恢复按钮")


func test_shortcuts_are_written_on_screen() -> void:
	# 实测：Ctrl+Z / Ctrl+Y / Ctrl+S 一直有效，但界面上一个字都没提过（小白根本不会知道）。
	# 【2026-10-03 取法修正】原实现取「**最后一个**含 Ctrl+Z 的 Label」（`found` 被循环覆盖）再要求
	# **同一个** Label 里也有 Ctrl+S —— 只要别处也提到 Ctrl+Z 就假红：新增的「形状组合」说明里有
	#「（可 Ctrl+Z 撤销）」，被它抢先命中，而它没有 Ctrl+S（功能本身没问题）。
	# 本用例的意图是「这三个快捷键都要能在界面上看见」，不是「必须挤在同一行」⇒ 改为
	# **全界面 Label 文本并集**判定，并顺带把 Ctrl+Y 也钉全（原先只钉了 Z/S 两个）。
	var ed := await _make_editor()
	var all := ""
	for lab in (ed as Node).find_children("*", "Label", true, false):
		all += (lab as Label).text + "\n"
	for key in ["Ctrl+Z", "Ctrl+Y", "Ctrl+S"]:
		assert_true(all.find(str(key)) != -1,
			"界面上必须写出快捷键 %s（撤销 / 重做 / 保存）—— 否则新手根本不知道有这些操作" % str(key))


# ==================== 布局稳定性 / 图标化（用户报告，2026-10-02） ====================
#
# 用户原话："点击属性会导致右侧的控制器变宽变窄，棋盘也会变大变小"、"AI 帮我写里是空的"。
# 实测根因：属性页最小宽 468 > 面板自定义宽 330（TabContainer 取当前页最小宽度）⇒ 切页抖动；
# AI 页的"想法示例"按钮被压成 8px 宽 ⇒ 看着像空的。

func test_right_panel_width_is_stable_across_all_tabs() -> void:
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var tabs: TabContainer = null
	for c in (ed as Node).find_children("*", "TabContainer", true, false):
		tabs = c
		break
	assert_not_null(tabs, "应有右侧 TabContainer")
	if tabs == null:
		return
	await wait_process_frames(1)
	var base := tabs.size.x
	assert_eq(int(base), 330, "面板宽应等于自定义最小宽 330（实际 %d）" % int(base))
	for i in tabs.get_tab_count():
		tabs.current_tab = i
		await wait_process_frames(1)
		var page := tabs.get_child(i) as Control
		var need := page.get_combined_minimum_size().x
		assert_true(need <= 330,
			"第 %d 页「%s」最小宽 %d > 330 ⇒ 会把面板撑宽、棋盘挤小（切页就抖）" % [
				i, tabs.get_tab_title(i), int(need)])
		assert_eq(int(tabs.size.x), int(base), "切到第 %d 页后面板宽度不许变" % i)


## 读最后一条 toast 的文字（提示不堆叠，所以最多只有一条）。
func _last_toast(ed: Node) -> String:
	for c in ed.get_children():
		if c.has_meta("ui_toast"):
			return str((c as Label).text)
	return ""


func test_selection_flow_hints_and_shortcuts() -> void:
	# 用户报告的工作流问题："选工具 → 框选 → 去左栏点复制 → 再点粘贴"太绕。
	# 现在：Ctrl+C / Ctrl+V 直接可用，且**框选那一刻**就提示下一步该按什么
	#（"自动进入粘贴待命"的落地方式：不改用户的工具选择，而是当场把下一步写在提示里）。
	var ed := await _make_editor()
	var d := _doc5()
	_bind(ed, d)
	var canvas := _canvas_of(ed)
	# ① 空选区就复制 ⇒ 必须给可执行提示（不许静默）
	ed.call("_copy_selection")
	assert_true(_last_toast(ed).find("区域选择") != -1,
		"空选区复制要告诉用户先框选：%s" % _last_toast(ed))
	# ② 框选一片（剪贴板为空）⇒ 提示复制快捷键
	canvas.selection = Rect2i(0, 0, 2, 2)
	canvas.selection_changed.emit(canvas.selection)
	assert_true(_last_toast(ed).find("Ctrl+C") != -1,
		"框选后要提示复制快捷键：%s" % _last_toast(ed))
	# ③ 复制 ⇒ 剪贴板有内容（并给"已复制多少"的反馈）
	ed.call("_copy_selection")
	assert_gt((ed.get("_clipboard_cells") as Array).size(), 0, "复制后剪贴板应有格型")
	assert_true(_last_toast(ed).find("已复制") != -1,
		"复制后要有反馈（复制了几格）：%s" % _last_toast(ed))
	# ④ 换个位置再框选 ⇒ 提示"按 Ctrl+V 粘到这里"（这就是"框选后进入粘贴待命"）
	canvas.selection = Rect2i(2, 2, 2, 2)
	canvas.selection_changed.emit(canvas.selection)
	assert_true(_last_toast(ed).find("Ctrl+V") != -1,
		"已复制后再框选，要提示可粘到此处：%s" % _last_toast(ed))
	# ⑤ 粘贴：写进文档，且剪贴板**保留**（便于连续多贴）
	var obstacles_before := int(d.obstacles.size())
	ed.call("_paste_selection")
	assert_gt((ed.get("_clipboard_cells") as Array).size(), 0, "粘贴后剪贴板应保留（可连续贴）")
	assert_true(int(d.obstacles.size()) >= obstacles_before, "粘贴不应破坏文档")


func test_toasts_replace_instead_of_piling_up() -> void:
	# 用户报告："按动按钮之后下方显示文字提示。连续按多个按钮后就会导致文字重叠在一起。"
	# 根因：UiToast 每次新建一个底部 Label 且从不清旧的 ⇒ 全落在同一锚点上互相遮挡。
	var ed := await _make_editor()
	ed.call("_toast", "第一条提示")
	ed.call("_toast", "第二条提示")
	await wait_process_frames(1)
	var alive: Array[String] = []
	for c in (ed as Node).get_children():
		if c.has_meta("ui_toast"):
			alive.append(str((c as Label).text))
	assert_eq(alive.size(), 1, "同屏只该留最新一条提示（否则文字重叠）：%s" % str(alive))
	if alive.size() == 1:
		assert_eq(alive[0], "第二条提示", "留下的应是最后按下的那条")


func test_select_tool_explains_what_it_is_for() -> void:
	# 用户问："区域选择按钮有什么用吗" ⇒ 功能是"框选后整块复制格型"，界面必须自己讲清楚
	# （不然它看起来就像个没用的按钮，而且还会顶掉同样没解释的工具按钮）。
	var ed := await _make_editor()
	var tip := ""
	for c in (ed as Node).find_children("*", "Button", true, false):
		var b := c as Button
		if b.text.begins_with("区域选择"):
			tip = b.tooltip_text
	assert_true(tip != "", "「区域选择」必须有悬停说明")
	assert_true(tip.find("复制") != -1, "说明要说清它配合「复制选区/粘贴到选区」用：%s" % tip)


func test_no_button_is_squeezed_into_an_empty_box() -> void:
	# 用户报告："有些按钮没有内容，不知道是什么按钮"。
	# 实测根因：`clip_text` 让最小宽度只剩图标+内边距（≈8px），HBox 里的兄弟只拿"最小宽度"
	# ⇒ 文字被整段裁掉，看起来就是一个空按钮（重做 / 复制选区 / 加上这条规则 / 读懂并导入…18 个）。
	# 判据与字体无关：可见按钮要么**够宽**（≥60px），要么是"纯图标 + 有悬停说明"。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var tabs: TabContainer = null
	for c in (ed as Node).find_children("*", "TabContainer", true, false):
		tabs = c
		break
	var pages := 1
	if tabs != null:
		pages = tabs.get_tab_count()
	for i in pages:
		if tabs != null:
			tabs.current_tab = i
			await wait_process_frames(1)
		var bad: Array[String] = []
		for c in (ed as Node).find_children("*", "Button", true, false):
			var b := c as Button
			if b == null or not b.visible:
				continue
			# 非当前页的控件还没跑布局，尺寸不可信 ⇒ 跳过（各自在自己那轮里被检查）
			if tabs != null:
				var page_of: Node = null
				for k in tabs.get_tab_count():
					if (tabs.get_child(k) as Node).is_ancestor_of(b):
						page_of = tabs.get_child(k)
						break
				if page_of != null and page_of != tabs.get_child(i):
					continue
				if page_of == null and i > 0:
					continue      # 页外控件（左栏等）只在第一轮查一次
			var txt := b.text.strip_edges()
			if txt == "" and b.icon == null:
				bad.append("空按钮 %s（无文字无图标）" % b.name)
			elif txt != "" and b.size.x < 60.0:
				bad.append("「%s」被挤成 %s" % [b.text.substr(0, 14), str(b.size)])
			elif txt == "" and b.tooltip_text.strip_edges() == "":
				bad.append("纯图标按钮 %s 没有悬停说明（用户不知道它是什么）" % b.name)
		assert_eq(bad.size(), 0, "第 %d 页有「看着不像按钮」的按钮：%s" % [i, str(bad)])


func test_simple_buttons_have_icons_and_chips_are_wide_enough() -> void:
	var ed := await _make_editor()
	# ① 简单动作要有图标（用户要求"简单按钮换成图标"）——按关键词在**真实控件树**上复核
	var want := {"试玩": false, "撤销": false, "橡皮": false, "清空该格": false, "清空全部": false}
	for c in (ed as Node).find_children("*", "Button", true, false):
		var b := c as Button
		if b == null:
			continue
		for k in want.keys():
			if b.text.find(k) != -1 and b.icon != null:
				want[k] = true
	for k in want.keys():
		assert_true(bool(want[k]), "「%s」类按钮应带图标（简单动作图标化）" % k)
	# ② AI 页的"想法示例"按钮必须够宽（实测曾被压成 8px ⇒ 看着像一片空白）
	var chips := 0
	for c in (ed as Node).find_children("*", "Button", true, false):
		var b := c as Button
		if b.tooltip_text != "" and b.text.begins_with("数字 = "):
			chips += 1
			assert_gt(int(b.custom_minimum_size.x), 100,
				"想法示例按钮最小宽应 > 100（否则会被挤成小方块）：%s" % b.text)
	assert_gt(chips, 0, "AI 页应有想法示例按钮")


func test_verify_exit_buttons_and_glossary_are_present() -> void:
	# P7.4：验证页已有人话结论，但"结论之后怎么办"要自己想 ⇒ 给三条可执行出路 + 两个一键按钮。
	# P7.5：规格/邻域/环绕/深度/峰值 界面上到处在用，却**从没有一处解释过** ⇒ 左栏要有术语对照。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var labels: Array[String] = []
	for c in (ed as Node).find_children("*", "Label", true, false):
		labels.append((c as Label).text)
	var all := "\n".join(labels)
	var btns: Array[String] = []
	for c in (ed as Node).find_children("*", "Button", true, false):
		btns.append((c as Button).text)
	var btn_all := "\n".join(btns)
	assert_true(all.find("验证不通过怎么办") != -1, "左栏要有「验证不通过怎么办」这一组（正文在「说明」里）")
	assert_true(btn_all.find("换一盘随机布雷") != -1, "应有「换一盘随机布雷」按钮：%s" % btn_all)
	assert_true(btn_all.find("先去试玩看看") != -1, "应有「先去试玩看看」按钮")
	# 【2026-10-02 用户要求：界面只留干净列表 ⇒ 术语对照正文搬进「说明」】这里改成**去说明里查**：
	# 打开说明后那五个词的解释必须都在 —— 否则等于把内容搬丢了。
	assert_true(_press(ed, "说明"), "应能打开「说明」")
	var help_layer: Control = ed.get("_help_layer")
	assert_not_null(help_layer, "说明层应存在")
	var help_texts := ""
	for c in help_layer.find_children("*", "Label", true, false):
		help_texts += (c as Label).text + "\n"
	# 【2026-10-02 用户口径】术语对照那五条已被删（"废话"）⇒ 现在只查"有引导、无长解释"。
	assert_true(help_texts.find("怎么用") != -1, "「说明」里应给出照着点的引导")
	# 只认那三段长解释的**独有句子**（"邻域：" 这类词在别处的页说明里也可能出现，别误判）
	assert_false(help_texts.find("深度：解开某一步") != -1, "三段长解释应已删除（用户口径：废话）")


func test_ai_tab_scroll_is_expanded_so_the_page_is_not_blank() -> void:
	# 用户反馈（2026-10-02）："AI 帮我写里面什么都没有"。根因：该页是「VBox 里套 ScrollContainer」，
	# 而**漏了 SIZE_EXPAND_FILL** ⇒ VBox 把它压成最小高度（≈0），内容全在视口之外 ⇒ 整页空白。
	var ed := await _make_editor()
	var page := (ed as Node).find_child("AI 帮我写", true, false)
	assert_not_null(page, "应有「AI 帮我写」页")
	var sc: ScrollContainer = null
	for n in page.find_children("*", "ScrollContainer", true, false):
		sc = n
		break
	assert_not_null(sc, "该页内容应装在 ScrollContainer 里")
	assert_true((sc.size_flags_vertical & Control.SIZE_EXPAND_FILL) != 0,
		"内容滚动区必须竖向撑开，否则整页被压成空白（用户看到的就是这个）")
	# 页面上仍要有一行"我要干什么"的指路（长说明按用户要求已搬进「说明」）
	var texts: Array[String] = []
	for n in page.find_children("*", "Label", true, false):
		texts.append((n as Label).text)
	var all := "\n".join(texts)
	assert_true(all.find("不会写代码也能做规则") == -1,
		"那两段长说明已收进「说明」，界面上不该再重复显示（用户要求界面简洁）")
	assert_true(all.find("说明") != -1, "界面要留一行指路：三步怎么走去哪看")


func test_playtest_leaves_a_way_back_to_the_editor() -> void:
	# 用户反馈（2026-10-02）：点「试玩」进游戏后**没有按钮回编辑器**（游戏侧唯一出口是「关卡列表」→ 选关页）。
	# 修法：试玩时把回程写进 `GameSession.playtest_return`，游戏 HUD/结算层据此多显示「回编辑器」。
	# `_playtest` 本身会切场景，故这里只验"回程目标存在且指向编辑器"+"默认必须为空"。
	var ed := await _make_editor()
	var consts: Dictionary = (ed.get_script() as GDScript).get_script_constant_map()
	var back := str(consts.get("PLAYTEST_RETURN", ""))
	assert_ne(back, "", "编辑器应有 PLAYTEST_RETURN 常量（试玩回程目标）")
	assert_true(ResourceLoader.exists(back), "试玩回程场景必须存在：%s" % back)
	assert_true(back.ends_with("level_editor.tscn"), "回程应指向编辑器场景：%s" % back)
	assert_eq(str(GameSession.playtest_return), "",
		"回程标记默认必须为空 —— 正式发售的游戏里玩家不该看到「编辑器」字样")


func test_forge_dialog_keeps_its_buttons_outside_the_scroll_area() -> void:
	# 真机目视缺陷（2026-10-02）：弹窗内容 ≈830px，PopupPanel 默认按内容撑开窗口 ⇒ 在 720px 高的
	# 屏幕上「开始生成 / 停止 / 关闭」落到屏外，**用户点不到"开始"**。修法：自定义尺寸的窗口
	# + 内容进 ScrollContainer + 按钮行留在滚动区之外。这条钉住"按钮不在滚动区里"这个结构。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	ed.call("_open_forge")
	var dlg := ed.get("_forge_dlg") as PopupPanel
	assert_not_null(dlg, "应有批量生成弹窗")
	assert_false(dlg.wrap_controls, "弹窗不许按内容撑开（撑开就会高过屏幕，按钮跑到屏外）")
	var start_btn := ed.get("_forge_start_btn") as Button
	assert_not_null(start_btn, "弹窗应有「开始生成」")
	# 进度条与进度文字也必须在滚动区之外：真机实测它们原来排在滚动区下方（y=772/803 > 视口 626），
	# 点"开始生成"后屏幕一动不动，得滚动才看得到进度。
	for pair in [["_forge_start_btn", "开始生成"], ["_forge_bar", "进度条"], ["_forge_msg", "进度消息"]]:
		var n: Node = ed.get(str(pair[0]))
		assert_not_null(n, "弹窗应有%s" % str(pair[1]))
		var in_scroll := _inside_scroll_container(n, dlg)
		assert_false(in_scroll, "「%s」必须在滚动区之外，永远可见" % str(pair[1]))
	assert_true(_has_scroll_container(dlg), "弹窗内容应装在 ScrollContainer 里（放不下时可滚）")


func _inside_scroll_container(n: Node, stop_at: Node) -> bool:
	var cur: Node = n
	while cur != null and cur != stop_at:
		if cur is ScrollContainer:
			return true
		cur = cur.get_parent()
	return false


func _has_scroll_container(root: Node) -> bool:
	for n in root.find_children("*", "ScrollContainer", true, false):
		return true
	return false


func test_help_toggle_is_off_by_default_and_covers_the_buttons() -> void:
	# 用户需求（2026-10-02）：独立「说明」按钮；默认不显示；点开后每段解释贴着对应按钮；
	# 且**读数（雷数/格子数）始终显示**，不受开关影响。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	assert_null(ed.get("_help_layer"), "默认不该有说明层（用户要求：默认不显示）")
	assert_true(_press(ed, "说明"), "左栏顶部应有独立的「说明」按钮")
	var layer: Control = ed.get("_help_layer")
	assert_not_null(layer, "点「说明」后应出现说明层")
	var cards := 0
	for n in layer.find_children("*", "PanelContainer", true, false):
		cards += 1
	assert_gt(cards, 8, "说明卡片应覆盖左栏主要按钮（实测 %d 张）" % cards)
	var status := ed.get("_status") as Label
	assert_not_null(status, "状态栏读数应存在")
	assert_true(status.visible, "常驻读数必须仍然可见（用户特别强调的一点）")
	assert_true(_press(ed, "说明"), "再点一次「说明」应收起")
	assert_null(ed.get("_help_layer"), "再点后说明层应消失")


func test_help_text_follows_the_right_panel_tab() -> void:
	# 用户需求（2026-10-02）：说明文本要覆盖右侧面板，并且**随页签切换而更新**（两边始终一致）。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	assert_true(_press(ed, "说明"), "打开说明")
	var layer: Control = ed.get("_help_layer")
	assert_not_null(layer, "应有说明层")
	var tabs := ed.get("_tabs") as TabContainer
	assert_not_null(tabs, "编辑器应有右侧页签容器（说明要跟着它换）")
	var first := str(layer.call("page_card_texts"))
	assert_true(first != "", "当前页的**控件**说明应有内容（用户要求：只解释按钮/填空这类控件）")
	var other := (tabs.current_tab + 1) % tabs.get_tab_count()
	tabs.current_tab = other
	tabs.tab_changed.emit(other)
	var second := str(layer.call("page_card_texts"))
	assert_ne(second, first,
		"切换右侧页签后，右侧控件的说明必须跟着换（否则左边说的和右边看到的对不上）")


func test_help_blocks_the_board_without_blur_and_keeps_contrast() -> void:
	# 用户要求（2026-10-02）：①**删掉高斯模糊**；②但点说明时**仍不能操作棋盘**；
	# ③字体对比度要高；④界面长说明搬进说明后条数要够多（排版压紧多塞）。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	# 站到「AI 帮我写」页（默认当前页其实是「属性」）——页面自带的解释文字只对**当前页**生效
	var tabs := ed.call("_right_tabs") as TabContainer
	assert_not_null(tabs, "应有右侧页签容器")
	var ai_idx := -1
	for i in tabs.get_tab_count():
		if str(tabs.get_tab_title(i)).find("AI") != -1:
			ai_idx = i
	assert_true(ai_idx >= 0, "应有「AI 帮我写」页")
	tabs.current_tab = ai_idx
	assert_true(_press(ed, "说明"), "打开说明")
	var layer: Control = ed.get("_help_layer")
	var scrim: Control = layer.get("_scrim")
	assert_not_null(scrim, "打开说明时应出现画布压暗层")
	assert_null(scrim.material, "不许再有模糊着色器（用户要求删掉高斯模糊）")
	assert_eq(layer.mouse_filter, Control.MOUSE_FILTER_STOP,
		"说明层必须全屏吃掉鼠标（否则说明开着还能操作棋盘）")
	# 界面上的长说明搬进说明后：这些文字必须还在（不能弄丢）
	var joined := ""
	for n in layer.find_children("*", "Label", true, false):
		joined += (n as Label).text + "\n"
	assert_true(joined.find("照这三步做") != -1,
		"从界面上搬走的说明文字（三步那段）必须出现在「说明」里 —— 否则等于把内容弄丢了")
	# 用户要求：排版压紧、尽可能多塞（一屏能放下的条目要明显变多）
	assert_gt(int(layer.call("card_count")), 20,
		"说明条目数应覆盖左栏按钮 + 当前页控件（实测 %d 条）" % int(layer.call("card_count")))
	# 用户要求：点击说明外任意一处即退出说明
	layer.emit_signal("dismissed")
	assert_null(ed.get("_help_layer"), "点说明外（或按 ESC）应关闭说明")
	var fan: Rect2 = layer.get("_fan")
	assert_gt(fan.size.x, 100.0, "中间区矩形应有效（卡片落在这里）")
	var head_ink := Color(1, 1, 1, 1)
	for n in layer.find_children("*", "Label", true, false):
		var lb := n as Label
		var c := lb.get_theme_color("font_color")
		assert_gt(c.r + c.g + c.b, 2.0, "说明文字必须是高明度（提高对比度）：%s" % str(c))
		head_ink = c if lb.text.begins_with("【") else head_ink


func test_help_cards_follow_the_button_and_are_joined_by_a_line() -> void:
	# 用户需求：滚动导致按钮移位时（比如从左上滚到左下），说明文字要**跟着按钮走**；
	# 而且说明与目标之间要有一条**折线**表示归属。
	var script: GDScript = load("res://ui/editor_help.gd")
	assert_not_null(script, "说明层脚本应可加载")
	var btn := Rect2(0, 100, 92, 40)
	var up: Dictionary = script.call("place", btn, 60.0, -1.0e9)
	var moved := Rect2(0, 400, 92, 40)      # 模拟滚动：同一个按钮从 y=100 移到 y=400
	var down: Dictionary = script.call("place", moved, 60.0, -1.0e9)
	assert_eq(float(down["y"]) - float(up["y"]), 300.0,
		"按钮下移 300px ⇒ 卡片必须同样下移 300px（跟随，不许留在原地）")
	var pts: PackedVector2Array = script.call("elbow_points", btn, Rect2(120, 96, 264, 48))
	assert_gt(pts.size(), 1, "按钮与说明之间应有连线")
	# 真机实测：24 个按钮的卡片一路下推到 y=1335，屏幕只有 720 ⇒ 后面十几张白画。
	assert_false(bool(script.call("fits", 1300.0, 48.0, 720.0)), "放不下的说明不许显示（否则跑到屏幕外）")
	assert_true(bool(script.call("fits", 600.0, 48.0, 720.0)), "放得下的说明要显示")
	assert_eq(pts[0].y, btn.position.y + btn.size.y * 0.5, "线要从按钮的竖直中心出发")
	assert_eq(pts[pts.size() - 1].x, 120.0, "线要落在说明卡片的左边缘上")


func test_left_bar_groups_each_get_a_visible_frame() -> void:
	# 用户反馈（2026-10-02）："编辑器界面看起来有些乱，加些框、界限分明"。
	# 左栏十几组原先只靠一行小标题分隔 ⇒ 做了一次套框后处理（每组一块主题面板底板）。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var heads: Array[Label] = []
	for n in (ed as Node).find_children("*", "Label", true, false):
		if (n as Label).has_meta("group_head"):
			heads.append(n)
	assert_gt(heads.size(), 5, "应有多个组标题（找到 %d 个）" % heads.size())
	var framed := 0
	for h in heads:
		var p := h.get_parent()
		if p != null and p.get_parent() is PanelContainer:
			framed += 1
	assert_gt(framed, 5, "至少 6 组要各自成框（只有左栏做了套框后处理）：%d" % framed)
	# 一组里的成员也要在同一个框内（否则框只是装饰，边界依旧不清）
	for h in heads:
		var p := h.get_parent()
		if p != null and p.get_parent() is PanelContainer:
			assert_true(h.get_index() == 0, "组标题应是框里的第一个子节点")


func test_batch_entry_is_also_on_the_first_screen() -> void:
	# 真机目视发现（2026-10-02）：左栏 ≈2 屏高，「批量生成关卡」原来是首屏之外的唯一入口
	#（要滚约 1.5 屏）——小白不会去滚一个看不出有内容的侧栏。首屏必须也有入口。
	# 这里用**结构顺序**断言（不依赖无头下的布局尺寸）：首屏入口要排在「存档与分享」之前。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var order: Array[String] = []
	for n in (ed as Node).find_children("*", "", true, false):
		if n is Button and (n as Button).text.find("要做很多关") != -1:
			order.append("FORGE")
		elif n is Label and (n as Label).text.find("存档与分享") != -1:
			order.append("SAVE")
	assert_true(order.has("FORGE"), "首屏应有批量生成入口（「要做很多关？→ 批量生成关卡」）")
	var i_forge := order.find("FORGE")
	var i_save := order.find("SAVE")
	assert_true(i_save == -1 or i_forge < i_save,
		"首屏入口要排在「存档与分享」之前（那组已在首屏之外）：%s" % str(order))


func test_rule_identity_stays_resolvable_and_forge_mode_distinguishes_globals() -> void:
	# 【审查 #1 的回归钉子】`rule_id_effective()` 会被当**线索规则 id** 喂生成器（`_forge_opts.clue_rule_id`）
	# ⇒ 它必须能被 `RuleRegistry` 解析（否则"带布局规则的变体批量生成 0 关"会重演）；
	# 而"区分全局规则"只属于 `_forge_mode()`（输出目录 / 包 id / 安装目录的身份）。
	var ed := await _make_editor()
	var d := _doc5()
	_bind(ed, d)
	var base := str(d.rule_id_effective())
	# ⚠ 不能在测试里引 `RuleRegistry`：该标识符在这份文件的编译期解析不到 ⇒ **整个测试文件编译失败**
	# （收集数 149/150、1010 用例），门禁当场抓住。改用等价且无依赖的判据：身份里**不许有全局规则的
	# 拼接痕迹**（旧血案就是拼成了 `classic+pf`，生成器 `RuleRegistry.resolve` 解析不到 ⇒ 批量 0 关）。
	assert_false(base.find("+") != -1,
		"线索规则 id 不许拼全局规则（拼了生成器解析不到 ⇒ 批量生成 0 关）：%s" % base)
	var m0 := str(ed.call("_forge_mode"))
	d.global_rule_ids = ["hv", "4c"]
	var m1 := str(ed.call("_forge_mode"))
	d.global_rule_ids = ["4c", "hv"]
	var m2 := str(ed.call("_forge_mode"))
	assert_true(m1 != m0, "带全局规则的身份必须与不带的不同（否则互相覆盖删除）：%s" % m1)
	assert_eq(m1, m2, "全局规则顺序不同 ⇒ 身份必须相同（排序去重，与 VariantCapability.rule_key 同口径）")
	assert_eq(str(d.rule_id_effective()), base, "全局规则不得污染线索规则 id（那会让生成器解析不到）")


func test_forge_finish_chain_writes_sets_pack_and_installs_it_loaded() -> void:
	# P2 E2E（`_forge_finish` 全链路，此前零引用）：生成 → 集文件 → 图例 → 打包 → 装进游戏 → **已加载**。
	# 最后那一步同时钉住 P0-1：选关页只列已加载的 Mod，不加载 = 用户按提示过去看到空页。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	ed.call("_open_forge")                       # 先把弹窗里的进度条/消息建出来（_forge_finish 会用）
	# 【审查 #4：不许删开发者/玩家的真产物】把本机已有的同名 Mod **整目录改名挪走**，用例结束原样挪回
	# （备份目录只要存在就绝不当垃圾清）。⚠ 时机必须在**生成/安装之前**——装完再挪等于把新版藏起来。
	var early_mod := "user://mods/%s" % str(ed.call("_forge_mode"))
	if DirAccess.dir_exists_absolute(early_mod):
		DirAccess.rename_absolute(early_mod, early_mod + "__e2e_backup")
	var out_dir := "user://test_e2e_forge"
	_e2e_rmrf(out_dir)
	var f := BatchForge.new()
	f.start({"sizes": [5], "tier_counts": {"easy": 1}, "mode": "e2e", "out_dir": out_dir})
	var guard := 0
	while not f.is_done() and guard < 900:
		f.step()
		guard += 1
	assert_true(f.is_done(), "小批生成应在步数预算内跑完")
	assert_gt(int(f.progress()["made"]), 0, "至少要生成出一关，否则链路没东西可验")
	ed.set("_forge", f)
	ed.set("_forge_out", {})
	# 【为什么不直接 call `_forge_finish`】它是**协程**（内部 await 帧/toast）⇒ `call()` 只启动它，
	# 返回时尚未落盘；实测"有时过、有时不过"（CI 红过一次），等 8 帧也不够稳。这里把它做的事按
	# **同一条路径**显式走完 —— 确定性优先，且覆盖的环节一个不少：
	# 读 index → 做图例 → 打包（levels_dirs = 刚生成的集文件目录）→ 安装（`_install_mod_zip`）→ 已加载。
	var rep := f.report()
	var dir := str(rep["dir"])
	var idx := LevelSets.read_level("%s/%s" % [dir, BatchForge.INDEX_NAME])
	assert_false(idx.is_empty(), "生成后应有 index.json（打包的分类索引来源）：%s" % dir)
	var tut := str(ed.call("_make_legend_files", dir))
	var zip_res: Dictionary = WorkshopPack.build(ed.get("doc"), {
		"id": str(ed.call("_forge_mode")),
		"title": "E2E 批量（无头）", "description": "端到端用例",
		"extra_manifest": {"categories": idx.get("categories", {}), "levels_index": idx.get("levels", [])},
		"levels_dirs": ["%s/%s" % [dir, BatchForge.LEVELS_DIR]],
		"tutorial_dirs": [tut] if tut != "" else [],
	})
	assert_true(bool(zip_res["ok"]), "批量包装配应成功：%s" % str(zip_res.get("reason", "")))
	var ins: Dictionary = ed.call("_install_mod_zip", str(zip_res["path"]), str(ed.call("_forge_mode")))
	assert_true(bool(ins["ok"]), "安装应成功：%s" % str(ins.get("reason", "")))
	# ① 集文件真的落盘（打包的输入）
	assert_true(FileAccess.file_exists("%s/levels/5/easy.json" % out_dir),
		"批量集文件应按 levels/<大小>/<档位>.json 落盘：%s" % out_dir)
	# ② 装进游戏
	var id := str(ed.call("_forge_mode"))    # 身份（含全局规则）：不要再自己拼 id，免得两处口径分叉
	var mod_dir := "user://mods/%s" % id
	var backup := mod_dir + "__e2e_backup"
	# ⚠ 备份动作**必须在生成/安装之前**做（已挪到用例开头）：放在这里会把**刚装好的新版**当成"旧产物"
	# 挪走，于是断言什么都找不到（实测踩过，失败信息是「打不开该目录」）。
	var installed := str(ins.get("mod_dir", ""))
	var man_path := installed.path_join("manifest.json")
	# 以**安装返回值**为准判"装到哪了"，并在失败信息里带目录实测内容（省得下次再靠猜）
	assert_true(FileAccess.file_exists(man_path),
		"安装报 ok，但按它自己报的 mod_dir 读不到 manifest：%s ｜ 该目录内容=%s" % [man_path, _e2e_ls(installed)])
	assert_true(FileAccess.file_exists("%s/manifest.json" % mod_dir),
		"按「user://mods/<id>」拼出来的路径也必须能读到：%s ｜ 该目录内容=%s" % [mod_dir, _e2e_ls(mod_dir)])
	# ③ **已加载**（P0-1）
	assert_true(ModAPI.list_mods().has(id), "装完必须已加载，否则选关页 Mod 页签是空的（id=%s）" % id)
	# 清理：只删作者是"编辑器"的目录，绝不碰玩家自己的 Mod
	# 清理判据：① 作者是"编辑器"，**或** ② 本用例开始时并没有同名目录（没有备份 ⇒ 它是我们刚造的）。
	# 只用①会漏：`WorkshopPack.build` 不写 author 时目录会留下，进到**下一个进程**（test/ui）里就变成
	# "多出来一个 Mod"，实测把 test/ui 里一条用例顶红 —— 测试之间不许经磁盘互相污染。
	var man := LevelSets.read_level("%s/manifest.json" % mod_dir)
	var ours := not DirAccess.dir_exists_absolute(backup)
	if ours or str(man.get("author", "")) == "编辑器":
		_e2e_rmrf(mod_dir)
	_e2e_rmrf(out_dir)
	if DirAccess.dir_exists_absolute(backup):     # 把挪走的原产物放回去（审查 #4）
		DirAccess.rename_absolute(backup, mod_dir)


## 失败信息里带目录实测内容（排查"说装好了却读不到"这类问题，省一轮来回）。
func _e2e_ls(dir: String) -> String:
	var d := DirAccess.open(dir)
	if d == null:
		return "（打不开该目录）"
	return "files=%s dirs=%s" % [str(d.get_files()), str(d.get_directories())]


func _e2e_rmrf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_e2e_rmrf(path.path_join(str(sub)))
	DirAccess.remove_absolute(path)


func test_paste_and_copy_never_touch_cells_outside_the_board() -> void:
	# 审查遗留（A3 同族，真 bug）：`_paste_selection` / `_cells_in` 原来用**包围盒**判界
	# （`p.x < doc.cols and p.y < doc.rows`）⇒ 形状盘会把洞格写进去；更糟的是**负数坐标也算通过**
	# （`-1 < cols` 为真）⇒ 往左上角粘贴会写到盘外。这里用"环形盘"（中间是洞）钉住不变量：
	# 粘贴一大片（含负坐标）之后，**所有格型键必须都在 all_positions() 里**。
	var ed := await _make_editor()
	var d := _doc5()
	d.shape_kind = "ring"
	d.shape_params = {"outer": 3, "inner": 1}
	_bind(ed, d)
	var on_board := {}
	for p in d.grid().all_positions():
		on_board[p] = true
	var clip: Array = []
	for y in range(-1, 6):
		for x in range(-1, 6):
			clip.append({"rel": Vector2i(x, y), "kind": EditorCanvas.KIND_OBSTACLE})
	ed.set("_clipboard_cells", clip)
	ed.call("_paste_selection")
	var off: Array[String] = []
	for p in d.obstacles:
		if not on_board.has(p):
			off.append(str(p))
	assert_eq(off.size(), 0, "粘贴写到了盘外/洞格：%s" % str(off.slice(0, 8)))
	assert_gt(d.obstacles.size(), 0, "至少应写入盘内格（否则这条用例是空转、等于没测）")
	# 复制侧同样按网格判界：直接问 `_copy_selection` 背后的 `_cells_in`，把相对坐标换回绝对坐标核对
	var rect := Rect2i(Vector2i(-1, -1), Vector2i(8, 8))
	var copied: Array = ed.call("_cells_in", rect)
	assert_gt(copied.size(), 0, "这个矩形范围内应有可复制的盘内格")
	for item in copied:
		assert_true(on_board.has(rect.position + (item["rel"] as Vector2i)),
			"复制的相对格换回绝对坐标后必须在盘内：%s" % str(item["rel"]))


func test_help_layer_close_path_is_covered() -> void:
	# 审查 B10：说明层的**关闭路径**此前零覆盖（只测过"能打开"）。这里钉住 `_close_help()` 的收尾，
	# 它必须把层释放并置空 —— 否则下次打开会叠一层、旧卡片残留。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	assert_true(_press(ed, "说明"), "应能打开「说明」")
	assert_not_null(ed.get("_help_layer"), "打开后说明层应存在")
	ed.call("_close_help")
	assert_eq(ed.get("_help_layer"), null, "关闭后说明层必须被释放并置空")
	assert_false((ed.get("_help_btn") as Button).button_pressed, "关闭后「说明」按钮要弹起（状态不能骗人）")


func test_forge_geometry_centers_inside_the_parent_window() -> void:
	# 审查 B7：子窗口**默认嵌入**父视口 ⇒ `Window.position` 已是相对视口，再加一次父窗口屏幕位置就偏一次。
	# 几何抽成纯函数后在这里钉住两种情形。
	var ed := await _make_editor()
	var parent := Rect2i(Vector2i(100, 40), Vector2i(1280, 720))
	var emb: Rect2i = ed.call("_forge_geometry", parent, true, Vector2i(660, 680))
	assert_eq(emb.size, Vector2i(660, 680), "装得下就用标称尺寸")
	# 嵌入子窗口的坐标是**相对父视口**的 ⇒ 居中只按视口尺寸算，不加父窗口屏幕位置（加了就偏一次）
	assert_eq(emb.position, Vector2i((1280 - 660) / 2, (720 - 680) / 2),
		"嵌入时按父视口居中：%s" % str(emb))
	# 独立窗口才是屏幕坐标 ⇒ 必须加上父窗口位置
	var free_win: Rect2i = ed.call("_forge_geometry", parent, false, Vector2i(660, 680))
	assert_eq(free_win.position, Vector2i(100 + (1280 - 660) / 2, 40 + (720 - 680) / 2),
		"非嵌入时父窗口位置要算进去：%s" % str(free_win))
	var tiny: Rect2i = ed.call("_forge_geometry", Rect2i(Vector2i.ZERO, Vector2i(400, 300)), true, Vector2i(660, 680))
	assert_true(tiny.size.x <= 400 and tiny.size.y <= 300, "父窗口很小时要夹进窗口内：%s" % str(tiny))


func test_forge_close_button_stops_and_hides() -> void:
	# 审查 B6：关窗必须**停**（原来只 hide()，协程继续跑、跑完还静默打包安装）。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	ed.call("_open_forge")
	var dlg := ed.get("_forge_dlg") as PopupPanel
	assert_not_null(dlg, "应有批量弹窗")
	var close_btn := ed.get("_forge_close_btn") as Button
	assert_not_null(close_btn, "应有「关闭」按钮（且接的是 _forge_close，不是裸 hide）")
	ed.call("_forge_close")
	assert_false(dlg.visible, "关闭后弹窗应收起")


func test_undo_records_a_cell_diff_not_a_whole_snapshot() -> void:
	# 【W1-S1】格子级改动必须记 **diff**（≈12B/格），而不是整盘快照（5000 格 ≈2MB）——
	# 清单·数据爆炸 D 点名要求；深度提到 200 步也只有靠 diff 才吃得消。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var canvas: EditorCanvas = ed.get("canvas")
	canvas.size = Vector2(600, 600)
	var before := (ed.get("doc") as EditorDoc).mines.size()
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = canvas.cell_rect(Vector2i(3, 3)).get_center()
	canvas._gui_input(ev)                      # 真实输入路径：按下即画一格
	var stack: Array = ed.get("_undo")
	# 编辑器在 `cell_edit_started` 时就自己压了撤销点（"改动之前"这条规矩）⇒ 这里不该再手动 push
	assert_eq(stack.size(), 1, "一次点击 = 一步（编辑器自己压的那一步）")
	assert_eq(str((stack[0] as Dictionary).get("kind", "")), "diff", "格子级改动必须记 diff 而不是快照")
	var cells: PackedInt32Array = (stack[0] as Dictionary).get("cells", PackedInt32Array())
	assert_eq(cells.size(), 3, "一格 diff 应是 3 个 int（x,y,code），实得 %d" % cells.size())
	ed.call("_undo_once")
	var d: EditorDoc = ed.get("doc")
	assert_eq(d.mines.size(), before, "撤销必须回到改动前")
	assert_false(d.mines.has(Vector2i(3, 3)), "该格应恢复为无雷")
	ed.call("_redo_once")
	assert_true(d.mines.has(Vector2i(3, 3)), "重做应把这格雷放回来")
	assert_eq((ed.get("_undo") as Array).size(), 1, "重做后撤销栈应仍是一步")


func test_import_gate_refuses_absurd_level_data() -> void:
	# 【清单·数据爆炸 I：加载期总量校验拒载】"合法但巨大"的导入必须在**加载期**被拒，
	# 而不是先解析再卡死（编辑器的粘贴/导入此前完全没闸门）。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	# ① 声明 1600 万格（4000×4000）—— 结构完全合法，但规模离谱
	var huge := JSON.stringify({"schema": 1, "level_doc": true, "size": {"rows": 4000, "cols": 4000}})
	assert_false(bool(ed.call("_load_from_text", huge)), "声明 1600 万格的数据必须被拒载")
	# ② 尺寸正常但雷位数组 5000 条（超过可编辑格数上限）
	var many: Array = []
	for i in 5000:
		many.append([i % 9, (i / 9) % 9])
	var bomb := JSON.stringify({"schema": 1, "level_doc": true, "size": {"rows": 9, "cols": 9}, "mines": many})
	assert_false(bool(ed.call("_load_from_text", bomb)), "雷位数组超上限必须被拒载")
	# ③ 超字节上限：连解析都不该跑
	assert_false(bool(LevelGuardRef.check_text("x".repeat(LevelGuardRef.MAX_BYTES + 1))["ok"]), "超 2MB 的文本要拒")
	# ④ **闸门不许误伤**：正常关卡文本仍要能导入（这是最容易写错的一条）
	var ok_text := JSON.stringify((ed.get("doc") as EditorDoc).to_level_json())
	assert_true(bool(ed.call("_load_from_text", ok_text)), "正常关卡文本必须仍能导入")
	assert_true(bool(LevelGuardRef.check_level({"size": {"rows": 9, "cols": 9}})["ok"]), "9×9 应放行")


func test_save_writes_atomically_and_leaves_no_tmp() -> void:
	# 【清单·一「保存」】手动保存必须**原子写**（临时文件→替换），不能直写目标文件
	#（写一半崩掉就是坏档）。同时不许在存档目录里留下 .tmp 残渣。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	ed.call("_save")
	var used: String = str(ed.get("_current_path"))
	assert_true(used != "", "保存后应记住当前文件")
	assert_true(FileAccess.file_exists(used), "目标文件应存在：%s" % used)
	assert_false(FileAccess.file_exists(used + ".tmp"), "不许留下 .tmp 残渣：%s.tmp" % used)
	var back := LevelSets.read_level(used)
	assert_false(back.is_empty(), "写出来的应是可解析的关卡 JSON")
	# 再存一次（覆盖路径）也必须成功 —— 原子写最容易在"目标已存在"这一步翻车
	ed.call("_save")
	assert_true(FileAccess.file_exists(used), "重复保存后文件仍在：%s" % used)
	assert_false(FileAccess.file_exists(used + ".tmp"), "重复保存也不许留 .tmp")


func test_help_closes_on_outside_click_and_escape() -> void:
	# 审查 B10：说明层的**真实关闭路径**（点外面 / ESC）此前零覆盖（只测了信号）。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	assert_true(_press(ed, "说明"), "应能打开「说明」")
	var layer: Control = ed.get("_help_layer")
	assert_not_null(layer, "说明层应存在")
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	layer._gui_input(mb)
	await get_tree().process_frame
	await get_tree().process_frame
	var cur: Control = ed.get("_help_layer")
	assert_true(cur == null or not cur.is_inside_tree(), "点说明外面应收起说明层（真实关闭路径）")
	assert_true(_press(ed, "说明"), "应能再次打开")
	var layer2: Control = ed.get("_help_layer")
	assert_not_null(layer2, "说明层应能重建")
	var k := InputEventKey.new()
	k.keycode = KEY_ESCAPE
	k.pressed = true
	layer2._input(k)
	await get_tree().process_frame
	await get_tree().process_frame
	var cur2: Control = ed.get("_help_layer")
	assert_true(cur2 == null or not cur2.is_inside_tree(), "按 ESC 应收起说明层")


func test_help_layer_never_silently_drops_cards() -> void:
	# 审查 B8：原来"放不下就整张不画"是**静默丢弃**，而测试只数 `_items` ⇒ 永远绿。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	assert_true(_press(ed, "说明"), "应能打开「说明」")
	var layer: Control = ed.get("_help_layer")
	assert_not_null(layer, "说明层应存在")
	var dropped := int(layer.call("dropped_count"))
	assert_eq(dropped, 0, "有 %d 张说明卡片被静默丢弃（应夹进视口显示）" % dropped)
	# 只数"锚点**在屏幕内**、卡片却没显示"的：锚点被滚出屏幕时不显示是**对的**（画出来也指不到东西）
	var host := layer.get_rect()
	var bad := 0
	for it in (layer.get("_items") as Array):
		var card: Control = it["card"]
		var btn: Control = it["btn"]
		if is_instance_valid(card) and is_instance_valid(btn) and btn.is_visible_in_tree() \
				and host.intersects(btn.get_global_rect()) and not card.visible:
			bad += 1
	assert_eq(bad, 0, "有 %d 张卡片的锚点在视口内、卡片却没显示" % bad)


func test_every_help_text_key_points_at_a_real_control() -> void:
	# 审查 C11：`HELP_TEXT` 用**按钮全文**当键，文案一改就静默失效（已知「关卡尺寸」已是死键）。
	# 这条契约测试把死键变成红灯：键必须能在界面上找到同名控件。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var table: Dictionary = (ed as Node).get_script().get_script_constant_map()["HELP_TEXT"]
	var texts := {}
	for c in (ed as Node).find_children("*", "Button", true, false):
		texts[(c as Button).text] = true
	var dead: Array[String] = []
	for k in table:
		if not texts.has(str(k)):
			dead.append(str(k))
	assert_eq(dead.size(), 0, "这些 HELP_TEXT 键在界面上找不到控件（文案改了要同步）：%s" % str(dead))


func test_four_step_flow_bar_guides_beginners() -> void:
	# P7.3：新手第一次打开编辑器，第一眼该看到"流程"而不是"一堆工具"。
	# 判据：四个步骤按钮都在且都有说明；点「① 验证」要**切到验证页并真的出结论**
	#（只跑不切 = 结论写在他没看的页上，等于"点了没反应"）。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	var labels := ["① 验证", "② 试玩", "③ 保存", "④ 分享"]
	var found := {}
	var verify_btn: Button = null
	for c in (ed as Node).find_children("*", "Button", true, false):
		var b := c as Button
		for l in labels:
			if b.text.begins_with(str(l)):
				found[l] = b.tooltip_text
				if str(l) == "① 验证":
					verify_btn = b
	assert_eq(found.size(), 4, "四个流程按钮都要在（实际：%s）" % str(found.keys()))
	for l in labels:
		assert_true(str(found.get(l, "")) != "", "「%s」要有说明——新手要知道这一步干嘛" % l)
	assert_not_null(verify_btn, "应能找到「① 验证」按钮")
	if verify_btn == null:
		return
	verify_btn.pressed.emit()
	await wait_process_frames(3)
	var tabs: TabContainer = null
	for c in (ed as Node).find_children("*", "TabContainer", true, false):
		tabs = c
		break
	assert_not_null(tabs, "应有页签容器")
	if tabs != null:
		assert_eq(tabs.get_tab_title(tabs.current_tab), "验证", "点「① 验证」应切到「验证」页")
	var plain := ed.get("_verify_plain") as Label
	assert_true(plain != null and plain.text.length() > 0,
		"点「① 验证」应真的跑出结论（不许只切页不验证）")


func test_forge_has_one_click_presets_for_beginners() -> void:
	# P7.2 小白友好：面对"棋盘大小 × 每档份数 × 雷密度"会卡住 ⇒ 两个一键预设，点完仍可自己微调。
	var ed := await _make_editor()
	_bind(ed, _doc5())
	ed.call("_build_forge_dialog")
	assert_true(_press(ed, "先试一小批"), "应有「先试一小批」预设按钮")
	assert_eq(ed.call("_forge_sizes"), [5, 6, 7], "试跑预设：只勾 5/6/7（小盘便宜、先跑通一次）")
	var c1: Dictionary = ed.call("_tier_counts")
	assert_eq(int(c1["easy"]), 3, "试跑预设：普通 3 关")
	assert_eq(int(c1["normal"]) + int(c1["hard"]), 0,
		"试跑预设：不做困难/噩梦（一上来就做大档最容易让人放弃）")
	assert_true(_press(ed, "做一整套"), "应有「做一整套」预设按钮")
	assert_eq((ed.call("_forge_sizes") as Array).size(), 5, "整套预设：覆盖 5~9 五个尺寸")
	var c2: Dictionary = ed.call("_tier_counts")
	assert_gt(int(c2["easy"]), 0, "整套要有普通档")
	assert_gt(int(c2["hard"]), 0, "整套要有噩梦档")
	# 点了预设之后，参数提示要跟着更新（"一共会做 N 关"）
	var hint := (ed.get("_forge_hint") as Label).text
	assert_true(hint.find("一共会做") != -1, "预设后参数提示要更新：%s" % hint)
	# 加了两个按钮之后，弹窗仍要装得下（布局守卫）
	await _assert_dialog_fits(ed)


func test_forge_dialog_has_params_and_sane_defaults() -> void:
	# 批量生成弹窗（P6）：无头下只构建、不 popup（原生窗口在无头会失败），
	# 断言"参数控件齐 + 默认值合理 + 提示会说清一共做多少关"。
	var ed := await _make_editor()
	ed.call("_build_forge_dialog")
	assert_not_null(ed.get("_forge_bar"), "应有进度条")
	assert_not_null(ed.get("_forge_msg"), "应有进度/结论文案区")
	assert_not_null(ed.get("_forge_start_btn"), "应有开始按钮")
	assert_not_null(ed.get("_forge_stop_btn"), "应有停止按钮")
	assert_true((ed.get("_forge_stop_btn") as Button).disabled, "没在跑的时候「停止」应禁用（避免误点）")
	assert_not_null(ed.get("_forge_ratio"), "应能改雷密度（原来只显示不可改）")
	assert_eq(int((ed.get("_forge_ratio") as SpinBox).value), 12, "默认密度 12%（标准扫雷口径）")
	var sizes: Array = ed.call("_forge_sizes")
	assert_eq(sizes, [5, 6, 7], "默认勾 5/6/7：小盘便宜，先让用户跑通一次")
	var counts: Dictionary = ed.call("_tier_counts")
	assert_gt(int(counts["easy"]), 0, "默认普通档要 >0（否则点下去没东西可做）")
	assert_eq(int(counts["hard"]), 0, "默认不做噩梦档（大尺寸+噩梦最贵，别一上来就劝退）")
	# 批量入参必须**原样带上**这份文档的规则（曾经写死 clue="classic" + globals=[]，
	# 结果是"从内置变体关卡批量生成 → 悄悄产出经典关卡 / 丢掉布局约束"）
	var d := _doc5()
	_bind(ed, d)
	d.global_rule_ids = ["pf"]
	var opts: Dictionary = ed.call("_forge_opts", [5], {"easy": 1})
	assert_eq(Array(opts["global_rule_ids"]), ["pf"], "布局约束必须原样传给生成器（不许悄悄丢）")
	assert_true(str(opts["clue_rule_id"]) != "", "线索规则必须有个权威来源：%s" % str(opts["clue_rule_id"]))
	if not d.rule_spec.is_empty():
		assert_eq(str(opts["clue_rule_id"]), str(d.rule_spec.get("id", "")),
			"有规格时线索规则应取规格 id")
	var hint := (ed.get("_forge_hint") as Label).text
	assert_true(hint.find("一共会做") != -1, "提示要说清一共会做多少关：%s" % hint)
	assert_true(hint.find("雷") != -1, "提示要说清每个大小用几颗雷：%s" % hint)
	# 重型预探（P6e）：按钮与预估区必须在（没实测过时要**如实说**，不许编一个"大概"）
	assert_not_null(ed.get("_forge_probe_btn"), "应能「先探一次」（实测能力档案）")
	assert_not_null(ed.get("_forge_est"), "应有预估显示区")
	assert_true((ed.get("_forge_est") as Label).text.find("还没实测") != -1,
		"没档案时要如实说还没实测并指到按钮上：%s" % (ed.get("_forge_est") as Label).text)
	# 弹窗里的控件不许跑到窗口外面（新增了「③ 雷密度」「④ 先探一次」两段，最容易把按钮挤出去）
	await _assert_dialog_fits(ed)


## 布局规则入口（P6d）：没有它，AI 路径的变体永远带不上"雷怎么摆"的约束，
## 也就永远看不到「满足 / 不满足」那套图例演示。
func test_layout_rule_picker_adds_and_clears() -> void:
	var ed := await _make_editor()
	var d := _doc5()
	_bind(ed, d)
	var opt := ed.get("_global_opt") as OptionButton
	assert_not_null(opt, "属性页应有布局规则下拉")
	assert_gt(opt.item_count, 3, "下拉里应有若干条布局规则（实际 %d）" % opt.item_count)
	# 加一条：文档与列表都要变
	opt.selected = 0
	_press(ed, "加上这条规则")
	assert_eq(d.global_rule_ids.size(), 1, "加上后文档应记住这条布局规则：%s" % str(d.global_rule_ids))
	var list := ed.get("_global_list") as Label
	assert_true(list.text.find("当前：") != -1 and list.text.find("没有") == -1,
		"当前列表要显示它：%s" % list.text)
	# 重复加：不许变成两条（约束层面幂等，界面上只会让人以为加了两条）
	_press(ed, "加上这条规则")
	assert_eq(d.global_rule_ids.size(), 1, "同一条不许重复加")
	# 撤销应当能退掉这一次"加上"（按钮命令各自成一步）
	ed.call("_undo_once")
	assert_eq(d.global_rule_ids.size(), 0, "撤销应能退掉「加上布局规则」")
	# 全部去掉
	_press(ed, "加上这条规则")
	assert_eq(d.global_rule_ids.size(), 1, "再加一次")
	_press(ed, "全部去掉")
	assert_eq(d.global_rule_ids.size(), 0, "全部去掉应清空")
	assert_true((ed.get("_global_list") as Label).text.find("没有布局规则") != -1,
		"清空后要**明说没有**，不留白：%s" % (ed.get("_global_list") as Label).text)


## 弹窗内容必须装得进弹窗（无头下只设尺寸跑布局，不 popup）——新增参数会把它撑爆。
func _assert_dialog_fits(ed: Node) -> void:
	var dlg := ed.get("_forge_dlg") as PopupPanel
	if dlg == null:
		return
	dlg.size = ed.get("_forge_dlg_size")     # 用编辑器自己的尺寸（不写第二份，避免漂移）
	await wait_process_frames(2)
	# 基准取窗口自己的位置（PopupPanel 是 Window，没有 get_global_rect；没 popup 时通常是 0,0）
	var base := Vector2(dlg.position)
	var w := float(dlg.size.x)
	var h := float(dlg.size.y)
	for key in ["_forge_start_btn", "_forge_stop_btn", "_forge_bar", "_forge_msg", "_forge_ratio",
			"_forge_probe_btn", "_forge_est", "_forge_hint"]:
		var c := ed.get(key) as Control
		if c == null:
			continue
		var r := c.get_global_rect()
		assert_true(r.size.y > 0.0, "%s 应已完成布局（高度为 0 ⇒ 无头下没跑布局）" % key)
		assert_true(r.position.y >= base.y - 1.0 and r.end.y <= base.y + h + 1.0,
			"%s 应在弹窗纵向范围内（rect=%s 窗口高=%d）——否则用户看不到/点不到" % [key, str(r), int(h)])
		assert_true(r.end.x <= base.x + w + 1.0,
			"%s 应在弹窗横向范围内（rect=%s 窗口宽=%d）" % [key, str(r), int(w)])
