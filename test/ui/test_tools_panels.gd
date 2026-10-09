# test_tools_panels.gd —— 右上角「更多」菜单与四个工具面板的接线契约
#
# 守四件事（缺一个都是「功能对玩家不可见」）：
#   ① 「更多」按钮真的存在、图标真的解析出来（SVG 静默降级只表现为"按钮没图案"）、无 tooltip；
#   ② 菜单四项齐全，点每项都开得出对应面板；
#   ③ 成就墙真的把内置目录渲染成卡片（不是空壳）；
#   ④ 同一时刻只有一层工具面板（连点不同入口不叠层），关闭按钮能关掉。
#
# 注：打开成就墙会做一次判定并可能写 user://achievements.json（"打开即刷新"是刻意行为），
# 因此本文件必须落在有状态串行片里 —— 见 tools/gut_shards.ps1 的隔离约定。
extends GutTest

const Shell := preload("res://ui/tool_shell.gd")
const Catalog := preload("res://core/achievement_catalog.gd")
const Service := preload("res://ui/achievement_service.gd")

var _view


func before_each() -> void:
	_view = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(_view)
	await get_tree().process_frame


func after_each() -> void:
	if GameSession.state != GameSession.State.IDLE:
		GameSession.state = GameSession.State.IDLE
		GameSession.board = null


func _find_by_meta(root: Node, key: String) -> Control:
	if root is Control and root.has_meta(key):
		return root as Control
	for c in root.get_children():
		var r := _find_by_meta(c, key)
		if r != null:
			return r
	return null


## PopupMenu 是 Window 而不是 Control（`_find_by_meta` 只认 Control），单独找一个。
func _find_menu(root: Node) -> PopupMenu:
	for c in root.get_children():
		if c is PopupMenu and c.has_meta("tools_menu"):
			return c as PopupMenu
		var r := _find_menu(c)
		if r != null:
			return r
	return null


func _find_all_by_meta(root: Node, key: String, out: Array) -> void:
	if root is Control and root.has_meta(key):
		out.append(root)
	for c in root.get_children():
		_find_all_by_meta(c, key, out)


func _overlay() -> Control:
	return _find_by_meta(_view, Shell.OVERLAY_META)


func _open(menu_id: int) -> void:
	_view.call("_on_tools_menu_pick", menu_id)


# ---- ① 入口 ----

func test_tools_button_exists_with_icon() -> void:
	var btn := _find_by_meta(_view, "tools_btn") as Button
	assert_not_null(btn, "右上角应有「更多」按钮（meta: tools_btn）")
	if btn == null:
		return
	assert_not_null(btn.icon, "工具箱图标必须解析成功（SVG 失败会静默降级为空图标）")
	assert_eq(str(btn.tooltip_text), "", "选关页已删除悬浮提示（2026-10-01 用户口径）")


func test_menu_has_four_entries() -> void:
	_view.call("_open_tools_menu")
	var menu := _find_menu(_view)
	assert_not_null(menu, "点「更多」应建出菜单（meta: tools_menu）")
	if menu == null:
		return
	assert_eq(menu.item_count, 4, "菜单应有 4 项：成就墙 / 解谜者画像 / 教学树 / 创作中心")
	assert_eq(menu.get_item_text(0), "成就墙", "第 1 项是成就墙")
	assert_eq(menu.get_item_text(3), "创作中心", "第 4 项是创作中心")


# ---- ② 四个面板都开得出来 ----

func test_achievement_wall_renders_catalog_cards() -> void:
	_open(1)
	var ov := _overlay()
	assert_not_null(ov, "成就墙应挂出一层工具面板")
	if ov == null:
		return
	var cards: Array = []
	_find_all_by_meta(ov, "ach_id", cards)
	assert_eq(cards.size(), Catalog.count(),
		"成就墙应把全部 %d 条内置成就渲染成卡片（实得 %d）" % [Catalog.count(), cards.size()])
	assert_not_null(_find_by_meta(ov, "ach_total"), "应有总进度条")


func test_radar_panel_has_chart_and_persona() -> void:
	_open(2)
	var ov := _overlay()
	assert_not_null(ov, "解谜者画像应挂出一层工具面板")
	if ov == null:
		return
	assert_not_null(_find_by_meta(ov, "radar_chart"), "应有三轴雷达图")
	assert_not_null(_find_by_meta(ov, "persona_title"), "应有画像标题")
	assert_not_null(_find_by_meta(ov, "radar_axis_observe"), "应有观测轴计数条")
	assert_not_null(_find_by_meta(ov, "radar_axis_structure"), "应有结构轴计数条")
	assert_not_null(_find_by_meta(ov, "radar_axis_conserve"), "应有守恒轴计数条")


func test_tutorial_tree_lists_chapters() -> void:
	_open(3)
	var ov := _overlay()
	assert_not_null(ov, "教学树应挂出一层工具面板")
	if ov == null:
		return
	var chapters: Array = []
	_find_all_by_meta(ov, "tut_chapter", chapters)
	assert_gte(chapters.size(), 5, "教学树至少 5 章（实得 %d）" % chapters.size())
	# 第 1 章必须解锁（否则新玩家打不开任何一课）
	assert_true(bool((chapters[0] as Control).get_meta("tut_unlocked")),
		"第 1 章必须默认解锁")


func test_creator_hub_has_publish_form() -> void:
	_open(4)
	var ov := _overlay()
	assert_not_null(ov, "创作中心应挂出一层工具面板")
	if ov == null:
		return
	assert_not_null(_find_by_meta(ov, "hub_publish"), "应有「登记」按钮")
	assert_not_null(_find_by_meta(ov, "hub_title"), "应有作品名输入框")


func test_publish_with_empty_title_is_rejected() -> void:
	_open(4)
	var ov := _overlay()
	assert_not_null(ov, "前置：创作中心已打开")
	if ov == null:
		return
	var btn := _find_by_meta(ov, "hub_publish") as Button
	assert_not_null(btn, "前置：登记按钮存在")
	if btn == null:
		return
	btn.pressed.emit()
	await get_tree().process_frame
	assert_not_null(_find_by_meta(_view, "ui_toast"), "空标题应弹提示而不是写一条空作品")


# ---- ③ 单层 / 可关闭 ----

func test_only_one_tool_overlay_at_a_time() -> void:
	_open(1)
	_open(2)
	_open(3)
	await get_tree().process_frame
	var all: Array = []
	_find_all_by_meta(_view, Shell.OVERLAY_META, all)
	assert_eq(all.size(), 1, "连点不同入口只应留一层面板（实得 %d 层）" % all.size())


func test_close_button_removes_overlay() -> void:
	_open(1)
	var ov := _overlay()
	assert_not_null(ov, "前置：面板已打开")
	if ov == null:
		return
	var close := _find_by_meta(ov, "tool_close") as Button
	assert_not_null(close, "面板应有自己的关闭按钮")
	if close == null:
		return
	close.pressed.emit()
	await get_tree().process_frame
	assert_null(_overlay(), "点关闭后面板应消失")
