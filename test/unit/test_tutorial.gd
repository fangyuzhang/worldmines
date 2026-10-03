extends GutTest

## 教程系统（对标游戏 doc10 §1.3）：格式解析 + 目录/加载。
## 教程用与谜题库完全不同的自定义文本格式：制表符分列、各行列数必须相等、
## `{注解}` 前缀、`?` 行终止盘面、空单元格做视觉留白（分组分隔）。





func test_clue_page_shows_varied_numbers_not_only_zeros() -> void:
	# 【2026-10-02 用户反馈："像热度的教程格子数字只有 0"】示例盘必须能看到 0 以外的数字，
	# 否则"数字怎么读"这一页等于没讲（一页多盘那版实现需要先改既有契约，见 rule_legend 顶部待办）。
	var built: Dictionary = RuleLegend.build_pages_for_ids("o5x", "o5x", [])
	assert_true(bool(built["ok"]), "应能生成页：%s" % str(built.get("reason", "")))
	var page := Tutorial.parse(str(((built["pages"] as Array)[0] as Dictionary)["text"]))
	assert_eq(str(page["error"]), "", "示例页要能解析：%s" % str(page["error"]))
	var values := {}
	for row in (page["rows"] as Array):
		for cd in (row as Array):
			values[str((cd as Dictionary)["value"])] = true
	var non_zero := false
	for v in values:
		if v != "" and v != "q" and v != "F" and v != "0":
			non_zero = true
	assert_true(non_zero, "示例盘上必须出现 0 以外的数字（否则用户只能看到一片 0）：%s" % str(values.keys()))


func test_generated_page_dict_is_normalized_for_drawing() -> void:
	# 【2026-10-02 真机截图：教程"只有文字、没有棋盘网格"】生成器页把**整份原文**放 `text`、盘面放
	# `layout`，而绘制端读 `rows`/`cols` ⇒ 左边无盘、右边把盘面行当正文。归一函数必须纠回来。
	var gen := {"id": "tutorial_o5x_0", "title": "数字怎么读",
		"text": "q\tq\tq\nq\t{@!}2\tq\n? 斜脉：数字 = 穿过它的斜线。", "layout": [], "kind": "clue"}
	var p := Tutorial.normalize_page(gen)
	assert_eq((p["rows"] as Array).size(), 2, "缺 rows 时应从 text 解析出盘面：%s" % str(p))
	assert_eq(int(p["cols"]), 3, "列数应为 3")
	assert_eq(str(p.get("title", "")), "数字怎么读", "标题应优先用生成器给的 title")
	assert_false(str(p["text"]).find("{@") != -1, "正文里不许再残留盘面注解：%s" % str(p["text"]))
	assert_true(str(p["text"]).find("斜脉") != -1, "正文要保留人话部分：%s" % str(p["text"]))
	var plain := {"id": "x", "text": "只有人话，没有盘面行"}
	var q := Tutorial.normalize_page(plain)
	assert_eq((q.get("rows", []) as Array).size(), 0, "没有盘面原文时不该凭空造格子")
	assert_eq(str(q.get("text", "")), "只有人话，没有盘面行", "正文应原样保留")


func test_parse_supports_multiple_boards_in_one_page() -> void:
	# 【2026-10-02 用户口径 B2：一页多盘】`--` 单独一行 = 盘面分隔符；`rows`/`cols` 仍是**第一张盘**
	#（这样"盘面行数 = DEMO_SIDE"等既有契约一行都不用改）。
	var p := Tutorial.parse("q\tF\n{@clue}1\tq\n--\n{@clue}2\tq\nq\t{@!}F\n? 三张盘一起看")
	assert_eq(str(p["error"]), "", "多盘页必须能解析")
	assert_eq((p["boards"] as Array).size(), 2, "应解析出两张盘")
	assert_eq((p["rows"] as Array).size(), 2, "兼容字段 rows 仍= 第一张盘")
	assert_eq(int(p["cols"]), 2, "列数取第一张盘")
	var b2: Dictionary = (p["boards"] as Array)[1]
	var r2: Array = b2["rows"]
	assert_eq(str(((r2[0] as Array)[0] as Dictionary)["value"]), "2", "第二张盘的内容要能读出来")
	assert_eq(str(p["text"]), "三张盘一起看", "`?` 之后仍是正文")
	var one := Tutorial.parse("q\tq\n? 单盘")
	assert_eq((one["boards"] as Array).size(), 1, "没有分隔符时仍只有一张盘（老文件不受影响）")


func test_clue_page_has_three_boards_with_varied_numbers() -> void:
	# 【2026-10-02 用户口径 B2】「数字怎么读」**一页三盘**（雷散/雷挤/贴边），且必须出现 0 以外的数字
	#（用户原话："像热度的教程格子数字只有 0，多放几个其他情况"）。
	var built: Dictionary = RuleLegend.build_pages_for_ids("o5x", "o5x", [])
	assert_true(bool(built["ok"]), "应能生成页：%s" % str(built.get("reason", "")))
	assert_eq((built["pages"] as Array).size(), 1, "页数契约不变（多盘在同一页里，不新增页）")
	var page := Tutorial.parse(str(((built["pages"] as Array)[0] as Dictionary)["text"]))
	assert_eq(str(page["error"]), "", "多盘页要能解析：%s" % str(page["error"]))
	assert_eq((page["boards"] as Array).size(), 3, "应是三张盘（雷散/雷挤/贴边）")
	var values := {}
	for board in (page["boards"] as Array):
		for row in ((board as Dictionary)["rows"] as Array):
			for cd in (row as Array):
				values[str((cd as Dictionary)["value"])] = true
	var non_zero := false
	for v in values:
		if v != "" and v != "q" and v != "F" and v != "0":
			non_zero = true
	assert_true(non_zero, "三张盘里必须出现 0 以外的数字（否则用户只能看到一片 0）：%s" % str(values.keys()))


func test_multi_board_extent_keeps_cells_visible() -> void:
	# 【B2 的可验证部分】三张盘竖排时：总行数要含盘间空隙，且按它算出的格子边长**不能小到看不见**。
	# （`_draw` 在无头下不渲染，"好不好看"只能人眼；但"放不放得下、会不会小于 2px"是纯数学，能钉。）
	var boards := [
		{"rows": [[{}], [{}], [{}], [{}], [{}]], "cols": 5},
		{"rows": [[{}], [{}], [{}], [{}], [{}]], "cols": 5},
		{"rows": [[{}], [{}], [{}], [{}], [{}]], "cols": 5},
	]
	var ext := Tutorial.boards_extent(boards)
	assert_eq(int(ext["rows"]), 17, "三张 5 行盘 + 2 行空隙 = 17 行：%s" % str(ext))
	assert_eq(int(ext["cols"]), 5, "最大列数取各盘最大")
	# 说明层的盘区约 360×300（`_grid.custom_minimum_size`），减掉 pad 12*2 后每格必须 ≥ 2px
	var cell := minf((360.0 - 24.0) / float(ext["cols"]), (300.0 - 24.0) / float(ext["rows"]))
	assert_gt(cell, 2.0, "三张盘的格子边长应大于绘制下限 2px（实得 %.1f）" % cell)
	assert_eq(int(Tutorial.boards_extent([])["rows"]), 0, "空盘列表要安全返回 0")


func test_placeholder_letters_have_visual_meaning() -> void:
	# 【2026-10-02 用户反馈：游玩中点教程"乱码、没有棋盘"】根因是绘制端把文档占位字母**当文字画**
	# （`tutorial_overlay.DemoGrid._draw` 里原来是 `draw_string(value)`）⇒ 满屏 q/F 字母。
	# 这里把语义钉死，防止哪天又被改回"一律 draw_string"。
	var src := "q\tF\tq\n{@clue}1\t{@!}q\tq\n"
	var p := Tutorial.parse(src)
	var row: Array = (p["rows"] as Array)[0]
	assert_eq(Tutorial.cell_visual(str((row[0] as Dictionary)["value"])), "covered",
		"q（未知/未翻开）必须画成盖着的格，不能当文字画")
	assert_eq(Tutorial.cell_visual(str((row[1] as Dictionary)["value"])), "mine",
		"F（雷）必须画成雷的图形，不能当文字画（也不用旗帜：用户口径「雷更直观」）")
	var row2: Array = (p["rows"] as Array)[1]
	assert_eq(Tutorial.cell_visual(str((row2[0] as Dictionary)["value"])), "text", "数字仍按文字画")
	assert_eq(Tutorial.cell_visual("x"), "text", "没约定的字母走文字路径（不静默吞掉内容）")
	assert_eq(Tutorial.cell_visual(" Q "), "covered", "前后空格/大小写也要认（文件里手写难免）")


func test_parse_basic_grid_and_annotations() -> void:
	var src := "q\tF\tq\n{@clue}1\t{@!}q\tq\n"
	var p := Tutorial.parse(src)
	assert_eq(p["error"], "", "应解析成功")
	assert_eq(p["cols"], 3, "列数应为 3")
	assert_eq((p["rows"] as Array).size(), 2, "应有 2 行")
	var cell = (p["rows"] as Array)[1][0]
	assert_eq(str(cell["value"]), "1", "注解应被剥掉，取值为 1")
	assert_eq((cell["annotations"] as Array).size(), 1, "应记录 1 条注解")
	# 注解按文档原样保留（`{@clue}` → `@clue`；文档写法为 `{@<clue>}V4`）
	assert_eq(str((cell["annotations"] as Array)[0]), "@clue", "注解应原样保留（含 @ 前缀）")


func test_parse_annotation_matches_doc_forms() -> void:
	# 文档四种写法：{@!} / {@<clue>} / {@<hover>} / {@x<wrong>}
	var src := "{@!}q\t{@<clue>}V4\t{@<hover>}F\t{@x<wrong>}q\n"
	var p := Tutorial.parse(src)
	assert_eq(p["error"], "", "应解析成功")
	var row: Array = (p["rows"] as Array)[0]
	assert_true(Tutorial.is_emphasis((row[0] as Dictionary)["annotations"]), "{@!} 应为高亮强调")
	assert_true(Tutorial.is_clue((row[1] as Dictionary)["annotations"]), "{@<clue>} 应为线索标注")
	assert_true(Tutorial.is_hover((row[2] as Dictionary)["annotations"]), "{@<hover>} 应为悬停示意")
	assert_true(Tutorial.is_wrong((row[3] as Dictionary)["annotations"]), "{@x<wrong>} 应为错误标记")
	assert_eq(str((row[1] as Dictionary)["value"]), "V4", "注解后的取值为 V4")


func test_parse_text_after_question_mark() -> void:
	var src := "q\tq\n? 第一行提示\n第二行提示\n"
	var p := Tutorial.parse(src)
	assert_eq(p["error"], "", "应解析成功")
	assert_eq((p["rows"] as Array).size(), 1, "`?` 之后不再计入盘面行")
	assert_eq(p["text"], "第一行提示\n第二行提示", "提示正文应为 `?` 之后的内容")


func test_parse_non_rectangular_is_error() -> void:
	var src := "q\tq\tq\nq\tq\n"
	var p := Tutorial.parse(src)
	assert_eq(p["error"], "Problem is not rectangular", "非等宽盘面必须报错")


func test_parse_empty_cell_marks_separator() -> void:
	var src := "q\t\tq\nF\t\tF\n"
	var p := Tutorial.parse(src)
	assert_eq(p["error"], "", "空单元格不是错误")
	assert_true(p["has_empty"], "含空单元格应置 has_empty")
	assert_eq(p["cols"], 3, "空单元格仍占一列")

	var no_empty := Tutorial.parse("q\tq\n")
	assert_false(no_empty["has_empty"], "无空单元格时 has_empty 应为 false")


func test_annotation_classifiers() -> void:
	assert_true(Tutorial.is_wrong(["x<wrong>"]), "x 前缀应为错误标记")
	assert_false(Tutorial.is_wrong(["!"]), "感叹号不是错误标记")
	assert_true(Tutorial.is_emphasis(["!"]), "感叹号应为高亮强调")
	assert_true(Tutorial.is_emphasis(["@!"]), "@! 也应为高亮强调")
	assert_true(Tutorial.is_hover(["<hover>"]), "含 hover 应为悬停示意")
	assert_true(Tutorial.is_hover(["@<hover>"]), "@<hover> 也应为悬停示意")
	assert_true(Tutorial.is_clue(["<clue>"]), "其余非空注解应视为线索标注")
	assert_false(Tutorial.is_clue(["x<wrong>"]), "错误标记不算线索标注")
	assert_false(Tutorial.is_clue([""]), "空注解不算线索标注")


## 真实教程文件：目录可枚举、能加载、盘面等宽、且顺序稳定。
func test_real_tutorial_files_load() -> void:
	var ids := Tutorial.list_ids()
	assert_gt(ids.size(), 0, "levels/tutorial 下应有教程文件")

	for id in ids:
		var page := Tutorial.load_page(id)
		assert_eq(page["error"], "", "%s 应能解析成功" % id)
		var rows: Array = page["rows"]
		assert_gt(rows.size(), 0, "%s 应有盘面行" % id)
		for r in rows:
			assert_eq((r as Array).size(), int(page["cols"]), "%s 各行应等宽" % id)
		assert_ne(str(page["text"]), "", "%s 应有提示正文" % id)


## pages_for 必须按序号数值排序（不是字符串排序，否则 _10 会排在 _2 前面）。
func test_pages_for_is_numerically_sorted() -> void:
	var pages := Tutorial.pages_for("classic")
	assert_gt(pages.size(), 0, "classic 应有多页教程")
	assert_eq(pages[0], "tutorial_classic_0", "第一页应为 _0")
	if pages.size() >= 2:
		assert_eq(pages[1], "tutorial_classic_1", "第二页应为 _1")


## 覆盖面守卫：每个内置机制至少有一页教程。
## 历史上教程只覆盖 classic（对标游戏有 61 个教学盘面），这条防止回退。
func test_covers_all_mechanisms() -> void:
	var combos := {}
	for id in Tutorial.list_ids():
		var body: String = id.substr("tutorial_".length())
		var cut := body.rfind("_")
		if cut > 0:
			combos[body.substr(0, cut)] = true
	for need in ["classic", "4n", "sc", "knight", "clock", "fr", "loopruns", "distsum", "hv",
			"mx", "rl", "pf", "qd", "dt", "ep", "4c", "combo"]:
		assert_true(combos.has(need), "机制 %s 应有教程页" % need)


## 教程覆盖层冒烟：能实例化、能构建 UI、能加载当前页。
func test_overlay_smoke() -> void:
	var script: Variant = load("res://ui/tutorial_overlay.gd")
	assert_true(script != null, "覆盖层脚本可加载")
	if script == null:
		return
	var ov: Control = script.new()
	add_child_autofree(ov)
	assert_true(ov.get_child_count() > 0, "覆盖层应构建出 UI 节点")
	ov.call("open")
	var title: Label = ov.get("_title")
	assert_true(title != null, "应构建出标题 Label")
	assert_true(title.text.find("tutorial_") >= 0, "标题应显示当前教程页 id：%s" % title.text)


## 覆盖层对不存在的页必须优雅降级（不崩溃）。
func test_overlay_handles_missing_page() -> void:
	var script: Variant = load("res://ui/tutorial_overlay.gd")
	if script == null:
		pending("覆盖层脚本不可用")
		return
	var ov: Control = script.new()
	add_child_autofree(ov)
	ov.call("open", ["tutorial_不存在_99"])
	var title: Label = ov.get("_title")
	assert_eq(title.text, "tutorial_不存在_99", "应显示页 id")
	var text: RichTextLabel = ov.get("_text")
	assert_true(text.text.find("解析失败") >= 0, "应提示解析失败而不是崩溃")


## 用户反馈（2026-10-02）："进入教程界面后背景全部高斯模糊，文字重叠看不清"。
## 根因：本覆盖层是全仓**唯一没有面板底板**的模态（只有一层 72% 黑遮罩），而各主题的页面背景是
## **烘焙好的毛玻璃**，下层文字透上来与教程文字叠在一起。修法：照 `settings_popup.gd` 的约定，
## 用 `PanelContainer` 承载主题面板样式当底板。这条钉住"控件确实落在底板之内"。
func test_overlay_content_sits_on_a_panel() -> void:
	var script: Variant = load("res://ui/tutorial_overlay.gd")
	if script == null:
		pending("覆盖层脚本不可用")
		return
	var ov: Control = script.new()
	add_child_autofree(ov)
	ov.call("open")
	var panel: PanelContainer = null
	for n in ov.find_children("*", "PanelContainer", true, false):
		panel = n
		break
	assert_not_null(panel, "教程内容应有面板底板（否则下层毛玻璃背景会透上来，文字看不清）")
	for key in ["_title", "_grid", "_text", "_prev_btn", "_next_btn"]:
		var node: Node = ov.get(key)
		assert_not_null(node, "缺控件 %s" % key)
		assert_true(panel.is_ancestor_of(node),
			"%s 必须落在底板之内（否则它会直接压在模糊背景上）" % key)


## pages_for 只认 `tutorial_<combo>_<纯数字>`（2026-09-23 审查加固）：
## 纯前缀匹配会把将来的混合档页（如 tutorial_s1_o1_0）也算成单席 s1 的页，
## 单席教程里就会混进混合档内容——现在没有混合档页，但名单增长时这种误匹配是静默的。
func test_pages_for_rejects_non_numeric_suffix() -> void:
	for combo in ["classic", "s1", "o1", "o10", "z2", "dt"]:
		var prefix := "tutorial_%s_" % combo
		for id in Tutorial.pages_for(combo):
			var seq := str(id).substr(prefix.length())
			assert_true(seq.is_valid_int(),
				"%s 的页 %s 序号应为纯数字（防混合档页误匹配）" % [combo, id])


## show_for 幂等：同一宿主重复调用复用已有覆盖层（连点「教程」不该叠出多层，
## 否则关掉一层还剩一层，用户以为按钮失灵）。
func test_show_for_is_idempotent() -> void:
	var script: Variant = load("res://ui/tutorial_overlay.gd")
	if script == null:
		pending("覆盖层脚本不可用")
		return
	var host := Control.new()
	add_child_autofree(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var first: Control = script.call("show_for", host, "classic")
	var second: Control = script.call("show_for", host, "classic")
	assert_not_null(first, "首次调用应建出覆盖层")
	assert_eq(second, first, "重复调用应复用同一层（连点不叠加）")
	var third: Control = script.call("show_for", host, "nonexistent_variant")
	assert_eq(third, first, "空态路径同样复用已有层")


## 不存在的页返回 error 而不是崩溃。
func test_load_missing_page_is_graceful() -> void:
	var page := Tutorial.load_page("tutorial_不存在_99")
	assert_ne(page["error"], "", "缺失页应返回 error")
	assert_eq((page["rows"] as Array).size(), 0, "缺失页盘面应为空")


## 6 个「与官方席位等价的旧实现」平移件：内容仍可达，且**与原件逐字一致**
##（clock→o8 / loopruns→o10 / pf→s1 / mx→z1 / rl→z2 / qd→z3，等价关系见
## variant_catalog.HIDDEN_RULES 注释）。
##
## 覆盖面与盘面自洽性已由 test_tutorial_pages.gd 统一守卫（官方席位全覆盖 + 数字核对 +
## 约束核对）；本测试只保留这里特有的那条：**平移件与原件同内容**——两边分叉会让
## 旧 id（legacy 关卡/旧存档仍可能引用）看到与官方席位不同的规则讲解。
func test_legacy_mirror_pages_match_originals() -> void:
	var pairs := {"o8": "clock", "o10": "loopruns", "s1": "pf",
		"z1": "mx", "z2": "rl", "z3": "qd"}
	for new_id in pairs:
		var new_pages := Tutorial.pages_for(new_id)
		var old_pages := Tutorial.pages_for(str(pairs[new_id]))
		assert_gt(new_pages.size(), 0, "%s 应能查到教程页" % new_id)
		assert_gt(old_pages.size(), 0, "%s 应能查到教程页" % str(pairs[new_id]))
		if new_pages.is_empty() or old_pages.is_empty():
			continue
		var new_text := str(Tutorial.load_page(new_pages[0]).get("text", ""))
		var old_text := str(Tutorial.load_page(old_pages[0]).get("text", ""))
		assert_eq(new_text, old_text,
			"%s 与原件 %s 的正文应一致（分叉会让两边讲不同的规则）" % [new_id, str(pairs[new_id])])


## show_for：入口共用的打开函数（2026-09-23）——有内容的变体加载出对应页；
## 无页变体优雅兜底（显示「暂无教程内容」而不是不弹或崩溃）。
## 注：官方席位已全部有页，兜底分支用**不存在的 id** 触发（见下）；幂等性见
## test_show_for_is_idempotent。
func test_show_for_loads_pages_or_falls_back() -> void:
	var script: Variant = load("res://ui/tutorial_overlay.gd")
	assert_true(script != null, "覆盖层脚本可加载")
	if script == null:
		return
	var host := Control.new()
	add_child_autofree(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	script.call("show_for", host, "o8")
	var ov: Control = null
	for c in host.get_children():
		if c.has_method("open"):
			ov = c
	assert_not_null(ov, "有教程的变体：show_for 应挂出覆盖层")
	if ov != null:
		var title: Label = ov.get("_title")
		assert_true(title.text.find("tutorial_o8") >= 0,
			"标题应显示 o8 的教程页（实得 %s）" % title.text)
		ov.queue_free()

	# 无页变体（不存在的 id）：仍须挂出覆盖层并显示兜底文案而不是不弹/崩溃。
	# 用假 id 而非某个真实变体——2026-09-23 起官方席位已全部有教程页，
	# 兜底路径的守卫不能再依赖「某个席位恰好缺内容」这种会过期的前提。
	# 用**独立宿主**：同一宿主会被 show_for 的防重入复用（那是另一条测试的断言）。
	var host2 := Control.new()
	add_child_autofree(host2)
	host2.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var ov2: Control = script.call("show_for", host2, "nonexistent_variant")
	assert_not_null(ov2, "无教程的变体也应挂出覆盖层（显示兜底文案）")
	if ov2 != null:
		var text: RichTextLabel = ov2.get("_text")
		assert_true(text.text.find("暂无教程") >= 0, "应显示「暂无教程内容」兜底（实得：%s）" % text.text)


## show_for 复用同一宿主时的行为（2026-09-23 审计修复）：第二次调用必须**重新加载**
## 新变体的页，而不是沿用上一批——原来是命中即 return，同帧内换变体看不到变化。
func test_show_for_reuses_host_and_reloads_pages() -> void:
	var script: Variant = load("res://ui/tutorial_overlay.gd")
	assert_true(script != null, "覆盖层脚本可加载")
	if script == null:
		return
	var host := Control.new()
	add_child_autofree(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	script.call("show_for", host, "o8")
	var first: Control = null
	for c in host.get_children():
		if c.has_method("open"):
			first = c
	assert_not_null(first, "第一次应挂出覆盖层")
	if first == null:
		return
	var t1: Label = first.get("_title")
	assert_true(t1.text.find("tutorial_o8") >= 0, "第一次应加载 o8 的页（实得 %s）" % t1.text)

	# 同一个宿主再开另一个变体：层数不增加、实例复用、内容必须换
	script.call("show_for", host, "o10")
	var layers := 0
	var second: Control = null
	for c in host.get_children():
		if c.has_method("open"):
			layers += 1
			second = c
	assert_eq(layers, 1, "防重入：同一宿主不应叠出第二层")
	assert_true(second == first, "应复用同一个覆盖层实例")
	var t2: Label = first.get("_title")
	assert_true(t2.text.find("tutorial_o10") >= 0,
		"复用时必须重新加载新变体的页（实得：%s）" % t2.text)
