# test_ui_rework_contract.gd —— 2026-09-28 UI 重构契约（用户 7 项决策的守卫）
#
# 守住三件事（改坏了都是「功能对玩家不可见」的静默缺失）：
#   ① 选关页右上角工具区：书本（图鉴）+ 齿轮（设置）—— **图标必须真的解析成功**：
#      `_svg_texture` 解析失败会静默返回 null（按钮照旧可点、只是没图案），只靠点击测不出来；
#   ② 齿轮 → 设置弹窗，且弹窗内有「完整设置…」入口 —— 主菜单删除后，整页设置（按键重绑 /
#      音效 / 皮肤 / 数据管理）**只有这一条通道**，缺了它那些功能彻底无入口；
#   ③ 对局 HUD = 顶栏 + 左右两列（左列 1 项 / 右列 3 项），且**不含**已删的「重开」「主菜单」。
extends GutTest

var _view


func before_each() -> void:
	_view = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(_view)
	# 异形页内容延迟一帧填（本测试不依赖它，稳妥起见等一帧让 _ready 后的状态稳定）
	await get_tree().process_frame


func after_each() -> void:
	# 齿轮用例会把设置弹窗挂到本页（Window，不随 Control 自动布局）；页面 autofree 时一并释放，
	# 这里只把对局状态收紧，避免污染后续用例。
	if GameSession.state != GameSession.State.IDLE:
		GameSession.state = GameSession.State.IDLE
		GameSession.board = null


# ---- 工具 ----

## 深度优先找第一个带指定 meta 的按钮（测试不依赖节点层级——层级重构不该让守卫失效）。
func _find_by_meta(root: Node, key: String) -> Button:
	if root is Button and root.has_meta(key):
		return root as Button
	for c in root.get_children():
		var r := _find_by_meta(c, key)
		if r != null:
			return r
	return null


func _collect_button_texts(node: Node, out: Array[String]) -> void:
	if node is Button:
		out.append(str((node as Button).text))
	for c in node.get_children():
		_collect_button_texts(c, out)


# ---- ① 右上角：书本 + 齿轮 ----

func test_corner_has_codex_and_gear_buttons() -> void:
	var book := _find_by_meta(_view, "codex_btn")
	var gear := _find_by_meta(_view, "settings_btn")
	assert_not_null(book, "选关页右上角应有「规则图鉴」按钮（meta: codex_btn）")
	assert_not_null(gear, "选关页右上角应有设置齿轮按钮（meta: settings_btn）")
	if book != null:
		assert_not_null(book.icon, "书本图标必须解析成功（SVG 解析失败会静默降级为空图标）")
		assert_ne(str(book.tooltip_text), "", "图鉴按钮应有 tooltip（纯图标控件的可读名称）")
	if gear != null:
		assert_not_null(gear.icon, "齿轮图标必须解析成功（SVG 解析失败会静默降级为空图标）")
		assert_ne(str(gear.tooltip_text), "", "齿轮按钮应有 tooltip")


# ---- ② 齿轮 → 设置弹窗（含整页设置入口）----

func test_gear_opens_settings_popup_with_full_settings_entry() -> void:
	var gear := _find_by_meta(_view, "settings_btn")
	assert_not_null(gear, "前置：齿轮按钮存在")
	if gear == null:
		return
	gear.pressed.emit()
	var popup: PopupPanel = null
	for c in _view.get_children():
		if c is PopupPanel:
			popup = c
	assert_not_null(popup, "点齿轮应弹出设置弹窗（复用对局内 settings_popup）")
	if popup == null:
		return
	assert_not_null(_find_by_meta(popup, "full_settings_btn"),
		"设置弹窗内应有「完整设置…」入口——主菜单删除后整页设置（按键/音效/皮肤/数据）的唯一通道")


# ---- ③ Mod 页管理入口 ----

func test_mod_page_has_manage_entry() -> void:
	_view._show_tab(_view.PAGE_MOD)
	var btn := _find_by_meta(_view, "mod_manage_btn")
	if ModAPI.list_mods().is_empty():
		# Mod 页在无 Mod 时不可达（_show_tab 回退第一页）——本机没装 Mod 时无从断言
		pending("本机没有已加载的 Mod，Mod 页不可达")
		return
	assert_not_null(btn, "Mod 页顶部应有「模组管理」入口（meta: mod_manage_btn）")


# ---- ④ HUD：顶栏 + 左右两列，且无「重开」「主菜单」 ----

func test_hud_two_columns_and_removed_buttons() -> void:
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	var hud: Control = load("res://ui/hud.tscn").instantiate()
	add_child_autofree(hud)
	await get_tree().process_frame

	assert_eq(hud._left_col.get_child_count(), 1, "左列应只有「关卡列表」一个按钮")
	assert_eq(hud._right_col.get_child_count(), 3, "右列应为 暂停 / 撤销 / 设置 三个按钮")
	var col_texts: Array[String] = []
	for b in hud._right_col.get_children():
		col_texts.append(str((b as Button).text))
	assert_eq(col_texts, ["暂停", "撤销", "设置"], "右列按钮顺序应与用户口径一致")
	assert_eq(str((hud._left_col.get_child(0) as Button).text), "关卡列表", "左列应是「关卡列表」")
	# 侧列空闲半透明（悬停显形的基础状态；常量是视觉契约的一部分）
	assert_almost_eq(hud._right_col.modulate.a, hud.SIDE_COL_IDLE_ALPHA, 0.01,
		"侧列应处于空闲半透明态")

	# 已删按钮不得以任何形式回来；关键入口不得丢
	var texts: Array[String] = []
	_collect_button_texts(hud, texts)
	assert_false(texts.has("重开"), "HUD 不得再有「重开」（进行中重开已按用户决策删除）")
	assert_false(texts.has("主菜单"), "HUD 不得再有「主菜单」（主菜单场景已删）")
	assert_true(texts.has("关卡列表"), "HUD 必须有「关卡列表」")
	assert_true(texts.has("教程"), "顶栏「教程」不得丢")
	# 「提示」按钮文本是动态的（充能中显示「提示 N%%」，禁用时置灰）——按前缀判定
	var has_hint := false
	for t in texts:
		if t.begins_with("提示"):
			has_hint = true
	assert_true(has_hint, "顶栏「提示」不得丢")
