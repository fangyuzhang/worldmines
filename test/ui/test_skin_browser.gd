# test_skin_browser.gd —— 皮肤浏览页与设置面板集成
extends GutTest


# B1：皮肤页能实例化并生成内置皮肤卡片
func test_b1_builds_cards() -> void:
	var page: Control = load("res://ui/skin_browser.tscn").instantiate()
	add_child_autofree(page)
	assert_not_null(page._grid, "网格应存在")
	assert_true(page._cards.size() >= 2, "至少生成两个内置皮肤卡片")


# B2：设置面板能打开（含皮肤选项卡），不崩溃
func test_b2_settings_panel_opens() -> void:
	var panel: Control = load("res://ui/settings_panel.tscn").instantiate()
	add_child_autofree(panel)
	var tabs := _find_first(panel, "TabContainer")
	assert_not_null(tabs, "设置面板应含 TabContainer")
	var has_skin_tab := false
	for c in tabs.get_children():
		if c.name == "皮肤":
			has_skin_tab = true
	assert_true(has_skin_tab, "应含「皮肤」选项卡")


func _find_first(node: Node, type_name: String) -> Node:
	if node.get_class() == type_name:
		return node
	for c in node.get_children():
		var r := _find_first(c, type_name)
		if r != null:
			return r
	return null
