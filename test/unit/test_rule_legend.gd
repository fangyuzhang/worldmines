extends GutTest

## 自创变体的图文图例（`core/rule_legend.gd`，P6）。
##
## 这里不验"能生成就算过"，而是对着**手算结果**断言：图例上的数字必须等于玩家在游戏里
## 看到的数字（两者都走 `Board` + 规则的正向求值）。数字漂移的图例比没有图例更糟。

const SPEC_ID := "spec_legend_test"


func after_each() -> void:
	# 注册表是进程级单例、没有 clear()：注入过就必须清，否则污染别的套件。
	RuleRegistry.default().unregister(StringName(SPEC_ID))


func _spec() -> Dictionary:
	# 周围 8 格求和：最经典的变体，图例数字可以手算核对
	var refs: Array = []
	var xs: Array = []
	var dirs: Array[Vector2i] = ClueEngine.ring_dirs()
	for i in dirs.size():
		refs.append({"dx": dirs[i].x, "dy": dirs[i].y})
		xs.append({"t": "ref", "i": i})
	return {"spec_version": 1, "id": SPEC_ID, "title": "图例测试用周围 8 格",
		"geometry": "rect_only",
		"clue": {"refs": refs, "expr": {"t": "sum", "xs": xs}, "max": 8}}


func test_legend_parses_and_numbers_match_hand_count() -> void:
	var built := RuleLegend.build_for_rule(SPEC_ID, _spec())
	assert_true(bool(built["ok"]), "规格规则应能生成图例：%s" % str(built["reason"]))
	var page := Tutorial.parse(str(built["text"]))
	assert_eq(str(page.get("error", "")), "",
		"图例必须能被仓库的教程解析器读懂（不许自创格式）：%s" % str(page.get("error")))
	assert_eq(int(page["cols"]), RuleLegend.DEMO_SIDE, "盘面列数应为 %d" % RuleLegend.DEMO_SIDE)
	assert_eq((page["rows"] as Array).size(), RuleLegend.DEMO_SIDE, "盘面行数应对")
	# 手算：雷在 (0,0)/(2,2)/(4,4)（列,行）。坐标 (1,1) 那格周围 8 格里有 (0,0) 与 (2,2) 两颗 ⇒ 2
	var rows: Array = page["rows"]
	var cell: Dictionary = (rows[1] as Array)[1]
	assert_eq(str(cell["value"]), "2",
		"中心格应为手算的 2（若是 0 或 8 ⇒ 图例没走规则、退回了经典口径）")
	# 注解在解析结果里带 `@` 前缀（`{@clue}2` ⇒ ["@clue"]）——这是 `Tutorial.parse` 的既有口径
	assert_true((cell["annotations"] as Array).has("@clue"), "数字格应带线索注解：%s" % str(cell))
	var mine_cell: Dictionary = (rows[0] as Array)[0]
	assert_eq(str(mine_cell["value"]), "F", "雷格应显示 F（图例里当作已标定）")


func test_legend_refuses_non_spec_rules_instead_of_faking_one() -> void:
	# 内置规则（classic 等）不是规格规则：没有可生成的图例，必须**如实拒绝**而不是编一张
	var built := RuleLegend.build_for_rule("classic", {})
	assert_false(bool(built["ok"]), "非规格规则生成不了图例")
	assert_true(str(built["reason"]).find("规格") != -1, "拒绝原因要说清：%s" % str(built["reason"]))


func test_legend_page_lands_where_the_game_looks_for_it() -> void:
	# 光会生成没用：写进 Mod 目录后，游戏里的教程系统必须找得到它（否则玩家看不到 = 白生成）
	var mods := "user://mods/legend_test_mod"
	_rmrf(mods)
	var res := RuleLegend.write_pages(SPEC_ID, _spec(), [], mods + "/tutorial")
	assert_true(bool(res["ok"]), "写图例应成功：%s" % str(res["reason"]))
	assert_eq(int(res["count"]), 1, "没有全局规则时只有「数字怎么读」一页")
	assert_true(str(res["path"]).ends_with(RuleLegend.page_id(SPEC_ID, 0) + ".txt"),
		"页 id 要符合教程命名契约：%s" % str(res["path"]))
	assert_true(Tutorial.search_dirs().has(mods + "/tutorial"),
		"教程搜索目录应包含该 Mod 的 tutorial：%s" % str(Tutorial.search_dirs()))
	assert_true(Tutorial.list_ids().has(RuleLegend.page_id(SPEC_ID, 0)), "教程列表要能列出它")
	var page := Tutorial.load_page(RuleLegend.page_id(SPEC_ID, 0))
	assert_eq(str(page.get("error", "")), "", "游戏侧要能读到这一页：%s" % str(page.get("error")))
	assert_eq((page["rows"] as Array).size(), RuleLegend.DEMO_SIDE, "读回来的盘面要完整")
	_rmrf(mods)


# ==================== P6b：布局规则的「满足 / 不满足」演示 ====================
#
# 参考用户给的另一款扫雷教程截图：一句话规则 + 棋盘演示（旗=雷；不满足的用红叉标出来）。
# 我们的红叉必须是**权威**的：违规布局要过 `RuleOracle.check`（生成器同款裁判）判定为假才上页面。

func _global_ids() -> Array:
	return ["pf"]      # pf = 任意 2×2 窗口 ≤ 2 雷（内置全局规则，place_mines 有契约测试兜着）


func test_layout_demos_show_satisfy_and_violate_with_marks() -> void:
	var built := RuleLegend.build_pages(SPEC_ID, _spec(), _global_ids())
	assert_true(bool(built["ok"]), "带全局规则的变体应能生成图例：%s" % str(built["reason"]))
	var pages: Array = built["pages"]
	assert_true(pages.size() >= 3,
		"应有 3 页：数字怎么读 + 满足 + 不满足（实际 %d 页）" % pages.size())
	if pages.size() < 3:
		return
	var ok_page: Dictionary = pages[1]
	var bad_page: Dictionary = pages[2]
	assert_eq(str(ok_page["kind"]), "ok", "第 2 页应是「满足」演示")
	assert_eq(str(bad_page["kind"]), "bad", "第 3 页应是「不满足」演示")

	# 满足页：用裁判复核它**真的合法**（不能只信插件）
	var judge := RuleOracle.new(RuleRegistry.default().resolve(StringName(SPEC_ID)),
		[RuleRegistry.default().resolve(&"pf")], Vector2i(RuleLegend.DEMO_SIDE, RuleLegend.DEMO_SIDE),
		(ok_page["layout"] as Array).size(), null)
	assert_not_null(judge, "裁判应能构造")
	assert_true(bool(judge.call("check", ok_page["layout"], {}, Vector2i(RuleLegend.DEMO_SIDE, RuleLegend.DEMO_SIDE))),
		"满足页的布局必须真的合法（用户拿它当正确答案看）")

	# 不满足页：裁判判违规 + 红叉标记存在
	assert_false(bool(judge.call("check", bad_page["layout"], {}, Vector2i(RuleLegend.DEMO_SIDE, RuleLegend.DEMO_SIDE))),
		"不满足页的布局必须真的违规（宁可缺页也不能教错）")
	assert_true(str(bad_page["text"]).find("{@x}") != -1,
		"违规雷必须用红叉标出来（教程渲染器的 {@x} 注解）")
	assert_true(str(bad_page["text"]).find("不满足") != -1, "文案要直说这是不满足的例子")

	# 两页都能被教程解析器读懂（否则玩家打开是空白 = 白生成）
	for p in [ok_page, bad_page]:
		var pg := Tutorial.parse(str(p["text"]))
		assert_eq(str(pg.get("error", "")), "", "演示页必须能被教程解析器读懂：%s" % str(pg.get("error")))
		assert_eq((pg["rows"] as Array).size(), RuleLegend.DEMO_SIDE, "演示盘面行数要完整")

	# 页 id 必须连续编号（教程系统的 pages_for 按序号翻页）
	assert_eq(str(ok_page["id"]), RuleLegend.page_id(SPEC_ID, 1), "满足页应为 1 号")
	assert_eq(str(bad_page["id"]), RuleLegend.page_id(SPEC_ID, 2), "不满足页应为 2 号")


func test_extra_layout_rules_are_declared_not_silently_dropped() -> void:
	# 演示最多带 2 条布局规则（页数/包大小的取舍）⇒ 但**剩下的必须说出来**，
	# 否则玩家会以为这个变体只有 2 条规则（静默省略＝骗人）。
	var built := RuleLegend.build_pages(SPEC_ID, _spec(), ["pf", "s1", "s2"])
	assert_true(bool(built["ok"]), "应能生成：%s" % str(built["reason"]))
	var pages: Array = built["pages"]
	assert_true(pages.size() >= 4, "应有：数字页 + 2 条规则演示 + 「其余规则」说明页（实际 %d）" % pages.size())
	var note: Dictionary = pages[pages.size() - 1]
	assert_eq(str(note["kind"]), "note", "最后一页应是说明页")
	assert_true(str(note["text"]).find("s2") != -1,
		"说明页要列出没做示例的规则 id：%s" % str(note["text"]))
	var pg := Tutorial.parse(str(note["text"]))
	assert_eq(str(pg.get("error", "")), "", "说明页也要能被教程解析器读懂：%s" % str(pg.get("error")))


func test_lenient_rules_are_not_faked() -> void:
	# 如果一条规则在演示盘上造不出违规例子，**必须如实说**（kind="note"），绝不能编一张假的红叉图
	var built := RuleLegend.build_pages(SPEC_ID, _spec(), ["classic"])
	# classic 是线索型不是全局型 ⇒ 没有布局演示页，不崩、不少页
	assert_true(bool(built["ok"]), "线索型 + 无全局规则也应出「数字怎么读」一页")
	assert_eq((built["pages"] as Array).size(), 1, "只应有数字演示一页")


func _rmrf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(str(f)))
	for sub in d.get_directories():
		_rmrf(path.path_join(str(sub)))
	DirAccess.remove_absolute(path)
