# test_codex_ui.gd —— 规则图鉴页（codex.tscn）
# 验证：页面可实例化、覆盖全部 15 个内置变体码、含返回按钮。
extends GutTest


## 实例化图鉴页（挂到测试树，随用例自动释放）
func _page() -> Control:
	var page: Control = load("res://ui/codex.tscn").instantiate()
	add_child_autofree(page)
	return page


func _all_text(root: Node) -> String:
	var out := ""
	for c in root.get_children():
		if c is Label:
			out += (c as Label).text + "\n"
		out += _all_text(c)
	return out


# C1：页面可实例化且标题正确
func test_c1_page_builds() -> void:
	var page := _page()
	assert_not_null(page, "图鉴页应能实例化")
	assert_true(_all_text(page).contains("规则图鉴"), "应含标题「规则图鉴」")


# C2：覆盖目录里的全部观测/线索变体码。
# 来源是变体目录（唯一事实源）而不是 VariantRegistry 的写死 15 码表：
# 那张表早已与实际注册的算子脱节（2026-09-18 变体池按 GDD 终版收敛后更明显）。
func test_c2_covers_all_variant_codes() -> void:
	var page := _page()
	var text := _all_text(page)
	var codes := VariantCatalog.clue_ids()
	assert_true(codes.size() > 0, "目录里应有观测 / 线索变体")
	for code in codes:
		assert_true(text.contains(code), "图鉴应收录变体码：%s" % code)


# C3：结构 / 守恒约束全部收录
func test_c3_covers_all_constraints() -> void:
	var page := _page()
	var text := _all_text(page)
	for code in VariantCatalog.global_ids():
		assert_true(text.contains(code), "图鉴应收录约束码：%s" % code)


# C4：含操作说明要点与返回按钮
func test_c4_basics_and_back_button() -> void:
	var page := _page()
	var text := _all_text(page)
	assert_true(text.contains("左键翻开"), "应说明左键翻开")
	assert_true(text.contains("提示"), "应说明提示功能")
	var found := false
	for c in page.get_children():
		if c is Button and (c as Button).text == "返回":
			found = true
	assert_true(found, "应含「返回」按钮")
