extends GutTest

## 设置面板的两条**布局稳定性契约**（2026-09-20 修掉的两个 bug 的防回归）。
##
## 两个 bug 的共同点：都是「结构上没错、但用起来是坏的」，且**静态检查与既有单测都发现不了**
## ——既有 test_settings_grouping.gd 只断言「控件存在且初值正确」，它俩照样全绿。
##
## bug 1（切到皮肤页后切不回去、别的选项也不显示了）：皮肤页根节点是个**裸 Control**，
##   不是 Container —— Container 才会计算并上报 minimum size，裸 Control 上报 0。
##   于是 TabContainer 计算内容尺寸时该页贡献 0，切过去整个面板塌缩，页签栏被挤出可视区。
## bug 2（换个选项就忽大忽小）：TabContainer 没固定尺寸，尺寸**由当前页内容决定**——
##   玩法页 8 项、音效页 1 项，切一次换一次大小；外面又是 CenterContainer 居中，
##   于是尺寸连着位置一起漂。
##
## ⚠️ 两条 bug 是**同一个量**：都是「切页导致面板尺寸变化」。所以下面
##   test_panel_size_stable_across_all_tabs（切遍所有页断言尺寸不变）**一个就钉住了两个**。
##
## ⚠️ 两条看起来合理、实则错误的判据（都实测过，别再走一遍）：
##   ① 用「页的 anchor 是否铺满」判覆盖 —— TabContainer **会自动**把子页锚点设成
##      FULL_RECT，五个页全都如此，照它判会全部误报。
##   ② 用「页是否上报 minimum size > 0」判塌缩 —— ScrollContainer 默认**不上报**
##      内容尺寸（4 个页都是 0），但外层尺寸已钉死时这**无害**，照它判也会误报。

const PANEL_PATH := "res://ui/settings_panel.tscn"


func _panel() -> Control:
	if not ResourceLoader.exists(PANEL_PATH):
		return null
	return load(PANEL_PATH).instantiate() as Control


## 递归找 TabContainer（面板是脚本构建的，层级会随重构变化，按类型找比按路径找耐用）。
func _find_tabs(root: Node) -> TabContainer:
	if root is TabContainer:
		return root
	for c in root.get_children():
		var r := _find_tabs(c)
		if r != null:
			return r
	return null


func test_panel_size_stable_across_all_tabs() -> void:
	var p := _panel()
	if p == null:
		pending("缺少 " + PANEL_PATH)
		return
	add_child_autofree(p)
	await get_tree().process_frame
	var tabs := _find_tabs(p)
	assert_not_null(tabs, "设置面板里应能找到 TabContainer")
	assert_true(tabs.get_tab_count() >= 2, "至少要有两个页签才谈得上「切页」")

	# 固定尺寸必须被显式钉死：不给 custom_minimum_size，尺寸就随当前页内容走
	assert_gt(tabs.custom_minimum_size.x, 0.0, "TabContainer 必须显式钉死宽度，否则切页会漂移")
	assert_gt(tabs.custom_minimum_size.y, 0.0, "TabContainer 必须显式钉死高度，否则切页会漂移")

	var base := tabs.size
	for i in tabs.get_tab_count():
		tabs.current_tab = i
		await get_tree().process_frame
		assert_eq(tabs.size, base, "切到第 %d 页（%s）后面板尺寸变了 —— 切页不应改变面板大小"
			% [i, tabs.get_tab_title(i)])


func test_plain_control_page_reports_its_size() -> void:
	var p := _panel()
	if p == null:
		pending("缺少 " + PANEL_PATH)
		return
	add_child_autofree(p)
	await get_tree().process_frame
	var tabs := _find_tabs(p)
	assert_not_null(tabs, "设置面板里应能找到 TabContainer")

	# 逐页检查：**任何**页都不允许铺满父容器（铺满 = 盖住页签栏 = 切不回去）。
	# 只查皮肤页会漏掉「以后有人给新页也加上 FULL_RECT」这种情况。
	for i in tabs.get_tab_count():
		tabs.current_tab = i
		await get_tree().process_frame
		var page := tabs.get_current_tab_control()
		if page == null:
			continue
		# 只对**裸 Control 页**（非 Container）要求自己上报尺寸：
		#   · Container（含 ScrollContainer）由引擎按内容算尺寸，它自身 min size 为 0 是
		#     **正常且无害**的——外层 TabContainer 尺寸已钉死，页会被拉伸填满，不会塌缩；
		#   · 裸 Control 上报 0 才会出事：TabContainer 算出的内容高度为 0 → 面板塌缩 →
		#     页签栏被挤出可视区（表现：切到皮肤页后切不回去、别的选项也不显示）。
		# （曾误用「anchor 铺满」当判据：TabContainer 会自动把子页设成 FULL_RECT，五页全中。）
		if page is Container:
			continue
		var minsz := page.get_combined_minimum_size()
		assert_gt(minsz.y, 0.0, "页「%s」是裸 Control 且未上报高度（minimum size = 0）"
			% tabs.get_tab_title(i)
			+ " —— 切到本页会让面板塌缩，页签栏被挤出可视区，等于切不回去")


func test_pages_are_scrollable_when_content_exceeds_panel() -> void:
	# 固定尺寸 + 不定长内容 ⇒ 必须可滚，否则高页（玩法页 8 项）被裁掉的部分无从访问。
	var p := _panel()
	if p == null:
		pending("缺少 " + PANEL_PATH)
		return
	add_child_autofree(p)
	await get_tree().process_frame
	var tabs := _find_tabs(p)
	assert_not_null(tabs, "设置面板里应能找到 TabContainer")

	for i in tabs.get_tab_count():
		tabs.current_tab = i
		await get_tree().process_frame
		var page := tabs.get_current_tab_control()
		if page == null:
			continue
		# 皮肤页是独立 .tscn，它内部自带 ScrollContainer —— 按「页内是否可达滚动容器」判定
		var has_scroll := page is ScrollContainer or _find_scroll(page) != null
		assert_true(has_scroll, "页「%s」没有滚动容器" % tabs.get_tab_title(i)
			+ " —— 面板尺寸已固定，内容超出时将被裁掉且无法访问")


func _find_scroll(root: Node) -> ScrollContainer:
	if root is ScrollContainer:
		return root
	for c in root.get_children():
		var r := _find_scroll(c)
		if r != null:
			return r
	return null
