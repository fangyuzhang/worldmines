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
	# 容器宽度必须容得下两个按钮（原先 80 < 88 ⇒ 齿轮被推出右缘；实测踩过）
	var bar: Control = gear.get_parent() as Control
	if bar != null:
		assert_gte(bar.size.x + 0.5, bar.get_combined_minimum_size().x,
			"右上角工具区宽度必须容得下两个图标按钮（实得 %.0f < 需要 %.0f）" % [
				bar.size.x, bar.get_combined_minimum_size().x])


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
	# 「教程 / 提示」2026-09-29 起是**图标按钮**（书本 / 灯泡），没有文字可扫，
	# 改按 meta 定位 —— 与本文件右上角书本/齿轮用例同一套查找方式。
	var tut := _find_by_meta(hud, "tutorial_btn")
	assert_not_null(tut, "顶栏「教程」入口不得丢（2026-09-29 起为书本图标按钮）")
	if tut != null:
		assert_not_null(tut.icon, "书本图标必须解析成功（SVG 解析失败会静默降级为空图标）")
		assert_ne(str(tut.tooltip_text), "", "纯图标控件必须有 tooltip（可读名）")
	var hint := _find_by_meta(hud, "hint_btn")
	assert_not_null(hint, "顶栏「提示」不得丢（2026-09-29 起为灯泡图标按钮，锚右上角）")
	if hint != null:
		assert_not_null(hint.icon, "灯泡图标必须解析成功")
		assert_ne(str(hint.tooltip_text), "", "纯图标控件必须有 tooltip（可读名）")


# ---- ⑤ 侧列与棋盘不重叠（2026-09-28 自查修复，防复发）----

func test_board_reserves_hud_side_columns() -> void:
	## 棋盘可用区必须扣除侧列宽度，否则左右边缘格子被按钮盖住（点不到、看不清）。
	## 这里锁住两处**独立声明**的常量同值——改一处忘另一处就是这个 bug 复发。
	var hud_res: float = float(load("res://ui/hud.gd").get_script_constant_map()["SIDE_COL_RESERVE"])
	var bv_res: float = float(load("res://ui/board_view.gd").get_script_constant_map()["HUD_SIDE_RESERVE"])
	assert_almost_eq(bv_res, hud_res, 0.001,
		"board_view.HUD_SIDE_RESERVE 必须 = hud.SIDE_COL_RESERVE")
	# 几何：棋盘左边界必须落在左列右边缘之外（侧列 = offset_left 12 + 按钮宽 84）
	var col_right: float = 12.0 + 84.0
	var board_left: float = 24.0 + bv_res
	assert_gte(board_left, col_right,
		"棋盘左边界（%.0f）必须在左列右边缘（%.0f）之外——否则边缘格子被按钮盖住" % [board_left, col_right])


func test_board_actual_layout_leaves_room_for_side_columns() -> void:
	## 端到端：真实 board_view 布局后的棋盘矩形必须落在两侧列之间。
	## 上一条用例只锁常量同值——如果 board_view 改用回了满宽公式（vp.x−48），常量断言仍会
	## 通过而棋盘照样被盖住；这条直接量**实际** board_origin / cell_px，堵住那个漏检。
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	var bv: Control = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(bv)
	await get_tree().process_frame
	var cols: int = GameSession.board.grid.size().x
	var left: float = bv.board_origin.x
	var right: float = left + float(cols) * float(bv.cell_px)
	var col_edge: float = 12.0 + 84.0   # 侧列占用：offset_left 12 + 按钮宽 84
	assert_gte(left, col_edge, "棋盘左边界（%.0f）必须让开左侧列（%.0f）" % [left, col_edge])
	assert_lte(right, 1280.0 - col_edge, "棋盘右边界（%.0f）必须让开右侧列（%.0f）" % [
		right, 1280.0 - col_edge])


# ---- ⑥ 图标随主题着色（浅色主题下白图标不可见的修复守卫）----

func test_icon_buttons_are_themed() -> void:
	for key in ["codex_btn", "settings_btn"]:
		var b := _find_by_meta(_view, key)
		assert_not_null(b, "前置：%s 存在" % key)
		if b == null:
			continue
		assert_true(b.has_theme_color_override("icon_normal_color"),
			"%s 必须显式覆盖 icon_normal_color（否则浅色主题下白图标不可见）" % key)
		assert_eq(b.get_theme_color("icon_normal_color"), ThemeManager.text(),
			"%s 的图标色应 = 当前主题文字色（随主题刷新）" % key)


# ---- ⑧ 对局内不提供整页设置入口（返回会离开对局）----

func test_hud_settings_popup_hides_full_settings_entry() -> void:
	## 对局内隐藏「完整设置…」：整页设置的「返回」是选关页，从对局进入会在返回时离开对局
	##（原行为：对局内只有子集弹窗、整页只在主菜单可达）。选关页侧则必须显示——那是整页
	## 设置唯一的通道（见用例 ②）。
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	var hud: Control = load("res://ui/hud.tscn").instantiate()
	add_child_autofree(hud)
	await get_tree().process_frame
	hud._open_settings()
	var popup: PopupPanel = hud._settings_popup
	assert_not_null(popup, "HUD 应能打开设置弹窗")
	if popup == null:
		return
	var more := _find_by_meta(popup, "full_settings_btn")
	if more != null:
		assert_false(more.visible, "对局内的设置弹窗不得显示「完整设置…」（返回会离开对局）")


# ---- ⑦ 侧列键盘焦点显形（无障碍）----

func test_side_column_reveals_on_keyboard_focus() -> void:
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	var hud: Control = load("res://ui/hud.tscn").instantiate()
	add_child_autofree(hud)
	await get_tree().process_frame
	var btn: Button = hud._right_col.get_child(0)
	btn.focus_entered.emit()
	assert_almost_eq(hud._right_col.modulate.a, 1.0, 0.01, "键盘焦点落在侧列按钮上应整列显形")
	btn.focus_exited.emit()
	assert_almost_eq(hud._right_col.modulate.a, hud.SIDE_COL_IDLE_ALPHA, 0.01, "失焦应回到半透明")
