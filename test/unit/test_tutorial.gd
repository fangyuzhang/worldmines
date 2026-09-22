extends GutTest

## 教程系统（对标游戏 doc10 §1.3）：格式解析 + 目录/加载。
## 教程用与谜题库完全不同的自定义文本格式：制表符分列、各行列数必须相等、
## `{注解}` 前缀、`?` 行终止盘面、空单元格做视觉留白（分组分隔）。


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
