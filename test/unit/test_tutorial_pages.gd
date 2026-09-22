# test_tutorial_pages.gd —— 教程页内容守卫（2026-09-23）
#
# 背景：教程入口改为「上下文相关」后（选关页弹窗 / 对局 HUD 点开的是**当前变体**的教程），
# 每个官方席位都必须有内容，否则入口点了只能看到「暂无教程内容」。补齐 16 席时还发现
# 历史教程页的盘面数字是「示意性」的（与规则实算不符——玩家照着数格子会被教错）。
# 本测试把两件事都钉成守卫：
#   ① 官方席位（VariantCatalog 三轴名单，唯一事实源）都有教程页；
#   ② 每页盘面的数字格 == 用规则实现（RuleRegistry）正向计算的值。
#
# 口径说明：
#   · 约束轴席位（s*/z*/dt/pf/mx/rl/qd/4c/ep 等 KIND_GLOBAL）没有自身的线索算法，
#     数字是经典 8 邻计数 → 用 classic 规则核算；
#   · `combo` 组合页正文自述「4N + 镜像」→ 数字按 4N 口径核算；
#   · 规则未加载（legacy Mod 未启用）的页面跳过（不误判）。
extends GutTest

## 全局约束型席位：数字走经典 8 邻计数。
const GLOBAL_SEATS: Array = ["s1", "s2", "s3", "s4", "s5", "s6", "s7",
	"z1", "z2", "z3", "z4", "z5", "dt", "pf", "mx", "rl", "qd", "4c", "ep"]
## 特例：组合页正文自述「4N + 镜像」→ 数字按 4N（正交计数）口径。
const CLUE_OVERRIDE: Dictionary = {"combo": "4n"}


## 官方席位全覆盖：名单直接取 VariantCatalog 的三轴常量（唯一事实源）——
## 以后变体池调整时，新席位若没配教程页，这里立刻红。
func test_official_seats_all_have_pages() -> void:
	for id in VariantCatalog.CLUE_ORDER + VariantCatalog.GLOBAL_ORDER:
		var pages := Tutorial.pages_for(str(id))
		assert_gt(pages.size(), 0,
			"官方席位 %s 应有教程页（否则入口点了只看到「暂无教程内容」）" % str(id))


## 每页盘面自洽：数字格显示的值必须等于规则实现在该雷布局下算出的线索值。
func test_every_page_board_matches_rule() -> void:
	var ids := Tutorial.list_ids()
	assert_gt(ids.size(), 0, "levels/tutorial 下应有教程页")
	for page_id in ids:
		_check_page(page_id)


func _check_page(page_id: String) -> void:
	var body: String = page_id.substr("tutorial_".length())
	var cut := body.rfind("_")
	var combo := body.substr(0, cut) if cut > 0 else body
	var clue_rule := "classic" if GLOBAL_SEATS.has(combo) else str(CLUE_OVERRIDE.get(combo, combo))
	var rule: Object = RuleRegistry.default().resolve(StringName(clue_rule))
	if rule == null:
		return  # 规则未加载（legacy Mod / 新算子）——跳过，不误判
	var page := Tutorial.load_page(page_id)
	assert_eq(str(page.get("error", "")), "", "%s 应能解析" % page_id)
	if str(page.get("error", "")) != "":
		return
	var rows: Array = page["rows"]
	var board := Vector2i(int(page["cols"]), rows.size())
	var mines := {}
	for r in rows.size():
		for c in (rows[r] as Array).size():
			if str(((rows[r] as Array)[c] as Dictionary).get("value", "")) == "F":
				mines[Vector2i(c, r)] = true
	for r in rows.size():
		for c in (rows[r] as Array).size():
			var cell: Dictionary = (rows[r] as Array)[c]
			var v := str(cell.get("value", ""))
			if v == "" or v == "q" or v == "F" or v == "D" or v == "∞":
				continue
			if Tutorial.is_wrong(cell.get("annotations", [])):
				continue  # 错误标记演示格（红叉），不是线索值
			if not v.is_valid_int():
				continue
			var expect: Variant = rule.call("compute_clue", mines, Vector2i(c, r), board)
			if not (expect is int):
				continue
			assert_eq(int(v), int(expect),
				"%s 格(%d,%d) 盘面数字与规则实算不符（clue=%s）" % [page_id, c, r, clue_rule])
