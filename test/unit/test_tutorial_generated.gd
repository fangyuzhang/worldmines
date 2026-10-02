extends GutTest

## 游戏内全部教程统一走生成器（P6f）：
## 玩家在游戏里点书本图标 ⇒ 看到的是**本变体专属**的「一句话规则 + 棋盘演示」
## （满足的例子 / 不满足的例子，违规雷用红叉标出——参考用户给的另一款扫雷的教程截图）。
## 静态 txt 只承担两件事：基本操作页（讲"怎么玩"）与生成失败时的回退。

const OverlayScript := preload("res://ui/tutorial_overlay.gd")


func test_builtin_clue_rule_generates_its_own_demo_page() -> void:
	# 前置守卫：o4 是随游戏发售的内置线索规则（capability 探针文档与规则测试都在用它）
	assert_not_null(RuleRegistry.default().resolve(&"o4"), "前置：o4 应已注册")
	var built := RuleLegend.build_pages_for_ids("o4", "o4", [])
	assert_true(bool(built["ok"]), "内置线索规则应能生成教程页：%s" % str(built["reason"]))
	var pages: Array = built["pages"]
	assert_gt(pages.size(), 0, "至少一页")
	var page: Dictionary = pages[0]
	assert_eq(str(page["kind"]), "clue", "第一页应是「数字怎么读」")
	assert_true(str(page["id"]).begins_with("tutorial_o4_"), "页 id 前缀 = 变体 id（教程命名契约）")
	var pg := Tutorial.parse(str(page["text"]))
	assert_eq(str(pg.get("error", "")), "", "必须能被教程解析器读懂：%s" % str(pg.get("error")))
	assert_true(str(page["text"]).find("\n? ") != -1, "盘面在前、`?` 之后是正文（教程格式）")
	# 文案要来自官方 rule_text（describe），不能是空壳
	var d: Dictionary = RuleRegistry.default().resolve(&"o4").call("describe")
	var official := str(d.get("rule_text", ""))
	assert_true(official != "" and str(page["text"]).find(official) != -1,
		"要引用官方规则文案（与图鉴/选关页同源）：%s" % official)


func test_builtin_global_rule_gets_satisfy_and_violate_pages() -> void:
	# pf（任意 2×2 ≤ 2 雷）：应有「满足」与「不满足」两页，且不满足页带红叉（{@x}）
	var built := RuleLegend.build_pages_for_ids("pf_demo", "", ["pf"])
	assert_true(bool(built["ok"]), "内置布局规则应能生成教程页：%s" % str(built["reason"]))
	var kinds: Array[String] = []
	for p in (built["pages"] as Array):
		kinds.append(str((p as Dictionary)["kind"]))
	assert_true(kinds.has("ok"), "要有「满足」演示页：%s" % str(kinds))
	assert_true(kinds.has("bad"), "要有「不满足」演示页（红叉标违规雷）：%s" % str(kinds))
	for p in (built["pages"] as Array):
		var pg := Tutorial.parse(str((p as Dictionary)["text"]))
		assert_eq(str(pg.get("error", "")), "", "每一页都要能被教程解析器读懂：%s" % str(pg.get("error")))


func test_overlay_shows_generated_pages_for_builtin_variant() -> void:
	# 用户视角：在游戏里点书本图标 ⇒ 第一页就是生成器现做的本变体演示（不是旧 txt）
	var host := Node.new()
	add_child(host)
	var ov: Control = OverlayScript.show_for(host, "o4")
	assert_not_null(ov, "应能打开教程覆盖层")
	var pages: Array = ov.get("_pages")
	assert_gt(pages.size(), 0, "应有页（o4 的生成页 + 基本操作页）")
	if pages.size() > 0:
		assert_true(pages[0] is Dictionary, "第一页应是生成器现做的内存页（不是旧 txt）")
		if pages[0] is Dictionary:
			assert_gt(str((pages[0] as Dictionary).get("text", "")).length(), 50,
				"生成页内容要非空")
	# 最后一页应是基本操作页（生成页讲规则，讲不了"怎么玩"）
	assert_eq(str(pages[pages.size() - 1]), "tutorial_basics_0",
		"基本操作页固定附在最后：%s" % str(pages))
	ov.call("close_overlay")


func test_overlay_falls_back_to_static_pages_for_unknown_id() -> void:
	# 解析不出规则的 id（例如组合示例 "combo"）⇒ 回退静态页，**不许**白屏也不许崩
	var host := Node.new()
	add_child(host)
	var ov: Control = OverlayScript.show_for(host, "combo")
	assert_not_null(ov, "应能打开覆盖层")
	var pages: Array = ov.get("_pages")
	for p in pages:
		assert_false(p is Dictionary, "回退路径不该混入生成页：%s" % str(p))
	ov.call("close_overlay")


func test_basics_page_exists_and_parses() -> void:
	assert_true(Tutorial.list_ids().has("tutorial_basics_0"),
		"应有基本操作页（任何变体通用，生成页讲不了「怎么玩」）")
	var page := Tutorial.load_page("tutorial_basics_0")
	assert_eq(str(page.get("error", "")), "", "基本操作页要能解析：%s" % str(page.get("error")))
	assert_true(str(page.get("text", "")).find("右键") != -1, "要讲到右键插旗")
