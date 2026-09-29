extends GutTest

## 交互 UI **布局契约**（2026-09-29 修的三个缺陷的防回归）。
##
## 三个缺陷（用户报的）：
##   #1 短文本 Label 的框过大      —— 写死 custom_minimum_size.x，短文案白占一列
##   #2 短文本 Label 不垂直居中    —— 同一个根因：**写死了框高 + Label.vertical_alignment
##                                    默认 TOP**，文字被顶在框顶，与同一行右侧的
##                                    按钮/开关/下拉中心错开 pad_y/2 px
##   #3 两列 HBoxContainer：左列该垂直居中、右列该上对齐（原来左列贴着顶，下方一片死白）
##
## 为什么必须单独立一份测试：这三个都是「结构上没错、代码能跑、既有断言全绿、只有截图能看出来」
## 的那一类。test_settings_grouping.gd 只断言控件存在与初值，这三个缺陷它一条都抓不到。
##
## ⚠️ 判定口径与 `_pv/analyze_ui_probe.py` 的 M1 **逐字一致**（改这里就要同步改那边）：
##   单行 = 框高 ≤ 1.6 × font.get_height(font_size)
##   装得下 = 文字宽 ≤ 框宽 + 0.5
##   不合格 = pad_y > 4 且 valign == TOP
## 不这样写就会重犯当年的错：把**自动换行**的标签也算进来（codex 的帮助文本天生
## pad_y 很大且 TOP 才对），计数被灌爆，测试变成噪音。

const PAD_Y_MAX := 4.0
const SINGLE_LINE_SLACK := 1.6
const FIT_SLACK := 0.5

## 参与扫描的界面（都是脚本建 UI 的交互面）。
## 故意不含对局中的 board_view / hud：那要真的 `GameSession.start_level()`（会生成盘面、
## 污染全局会话状态），代价与风险都远超它带来的覆盖 —— hud 实测 pad=(0,0)，本来就是干净的。
const SURFACES := {
	"settings_panel": "res://ui/settings_panel.tscn",
	"settings_popup": "res://ui/settings_popup.tscn",
	"pause_menu": "res://ui/pause_menu.tscn",
	"codex": "res://ui/codex.tscn",
	"skin_browser": "res://ui/skin_browser.tscn",
	"mod_select": "res://ui/mod_select.tscn",
	"level_select": "res://ui/level_select.tscn",
	"game_over": "res://ui/game_over.tscn",
	"drawing_toolbar": "res://ui/drawing_toolbar.tscn",
}


# ============================ 工具 ============================

func _host() -> Control:
	var h := Control.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child_autofree(h)
	return h


func _settle(n: int = 10) -> void:
	for i in n:
		await get_tree().process_frame


func _find_all(n: Node, cls: String, out: Array) -> void:
	for c in n.get_children():
		if c.is_class(cls):
			out.append(c)
		_find_all(c, cls, out)


func _find_first(root: Node, cls: String) -> Node:
	var hits: Array = []
	_find_all(root, cls, hits)
	return hits[0] if hits.size() > 0 else null


## 实例化一个界面并放进宿主；失败返回 null。
func _mount(scene: String, host: Control) -> Node:
	if not ResourceLoader.exists(scene):
		return null
	var n: Node = load(scene).instantiate()
	host.add_child(n)
	return n


## 弹窗类界面（PopupPanel / PopupMenu）必须真的 popup 一次：它是 Window，不弹出时
## 没有结算尺寸，子节点几何全是默认值 —— 照那个量会得到满屏假违规。
func _show_if_popup(n: Node) -> void:
	if not (n is Window):
		return
	if n.has_method("popup_center_refreshed"):
		n.call("popup_center_refreshed")
	else:
		(n as Window).popup_centered()


## 递归收集 Label，连同它的「框几何 vs 文字几何」一起返回。
func _walk_labels(root: Node, out: Array, tag: String = "") -> void:
	for c in root.get_children():
		if c is Label:
			var lb: Label = c
			var f: Font = lb.get_theme_font("font")
			if f != null:
				var fs: int = lb.get_theme_font_size("font_size")
				var lh := f.get_height(fs)
				var tw := f.get_string_size(lb.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				out.append({
					"lb": lb, "tag": tag, "box_w": lb.size.x, "box_h": lb.size.y,
					"text_w": tw, "line_h": lh,
					"single": lb.size.y <= SINGLE_LINE_SLACK * lh,
					"fits": tw <= lb.size.x + FIT_SLACK,
					"pad_y": lb.size.y - lh,
					"valign": lb.vertical_alignment,
					"row": lb.has_meta("_row_label"),
				})
		_walk_labels(c, out, tag)


## 收集整个界面里所有打了 _row_label 标记的标签（= 同一张表单的标签列成员）。
func _row_labels(root: Node) -> Array:
	var all: Array = []
	_walk_labels(root, all)
	var out: Array = []
	for d in all:
		if d["row"]:
			out.append(d)
	return out


# ============================ 缺陷 #1 / #2 ============================

## 全交互面扫描：不允许存在「单行、文字装得下、却把文字顶在框顶」的 Label。
func test_no_single_line_label_is_pinned_to_the_top_of_its_box() -> void:
	var host := _host()
	var checked := 0
	for name in SURFACES:
		var n := _mount(SURFACES[name], host)
		if n == null:
			continue
		_show_if_popup(n)
		await _settle(12)

		# 设置面板是多页签的，每页都要量（各页项数差别大，问题也各不相同）
		var tabs := _find_first(n, "TabContainer") as TabContainer
		var roots: Array = []
		if tabs != null and tabs.get_tab_count() > 0:
			for i in tabs.get_tab_count():
				tabs.current_tab = i
				await _settle(6)
				roots.append([tabs.get_child(i), "%s/%s" % [name, tabs.get_tab_title(i)]])
		else:
			roots.append([n, name])

		for pair in roots:
			var labels: Array = []
			_walk_labels(pair[0], labels, pair[1])
			checked += labels.size()
			for d in labels:
				if d["single"] and d["fits"] and d["pad_y"] > PAD_Y_MAX \
						and d["valign"] == VERTICAL_ALIGNMENT_TOP:
					assert_eq(d["valign"], VERTICAL_ALIGNMENT_CENTER,
						"[%s] Label「%s」单行、装得下，却被顶在框顶：框高 %.0f vs 行高 %.0f"
						% [d["tag"], str((d["lb"] as Label).text).substr(0, 16),
							d["box_h"], d["line_h"]]
						+ " —— 会与同一行的控件中心错开 %.1f px。请给该 Label 设 vertical_alignment = CENTER"
						% (d["pad_y"] / 2.0))

		n.queue_free()
		await _settle(4)
	# 断言「真的量到了东西」——否则把 SURFACES 清空也能绿
	assert_gt(checked, 100, "只量到 %d 个 Label，界面扫描显然没跑起来" % checked)


## 设置面板：同一页内所有行标签必须等宽，且不窄于最宽的文字。
func test_settings_row_label_column_is_uniform() -> void:
	var host := _host()
	var p := _mount("res://ui/settings_panel.tscn", host)
	if p == null:
		pending("缺少 settings_panel.tscn")
		return
	await _settle(14)
	var tabs := _find_first(p, "TabContainer") as TabContainer
	assert_not_null(tabs, "设置面板里应能找到 TabContainer")
	for i in tabs.get_tab_count():
		tabs.current_tab = i
		await _settle(6)
		var page_name := tabs.get_tab_title(i)
		var rows := _row_labels(tabs.get_child(i))
		if rows.size() < 2:
			continue
		var w: float = (rows[0]["lb"] as Label).custom_minimum_size.x
		assert_gt(w, 0.0, "页「%s」的行标签没有统一列宽（custom_minimum_size.x = 0）" % page_name)
		for d in rows:
			var lb: Label = d["lb"]
			assert_almost_eq(lb.custom_minimum_size.x, w, 0.01,
				"页「%s」的列宽不一致：Label「%s」= %.0f，其余 = %.0f"
				% [page_name, str(lb.text).substr(0, 12), lb.custom_minimum_size.x, w])
			assert_gte(w, d["text_w"] - FIT_SLACK,
				"页「%s」列宽 %.0f 小于 Label「%s」的文字宽 %.1f —— 会被裁字"
				% [page_name, w, str(lb.text).substr(0, 12), d["text_w"]])


## mod_select：顶层行标签（目标档位 / 示例行 / mod 行 / 自定义规则行）必须共用同一条列宽。
## 这是「安装按钮比下面的加载/卸载凸出 36px」那个参差列的防回归。
func test_mod_select_list_rows_share_one_column_width() -> void:
	var host := _host()
	var m := _mount("res://ui/mod_select.tscn", host)
	if m == null:
		pending("缺少 mod_select.tscn")
		return
	await _settle(16)
	var rows := _row_labels(m)
	assert_gte(rows.size(), 3, "mod_select 至少应有 3 条顶层行标签（档位 / 两条示例行）参与统一列宽")
	var w: float = (rows[0]["lb"] as Label).custom_minimum_size.x
	assert_gt(w, 0.0, "mod_select 的行标签没有统一列宽")
	for d in rows:
		var lb: Label = d["lb"]
		assert_almost_eq(lb.custom_minimum_size.x, w, 0.01,
			"mod_select 列宽不一致：Label「%s」= %.0f，其余 = %.0f"
			% [str(lb.text).substr(0, 12), lb.custom_minimum_size.x, w])


# ============================ 缺陷 #3 ============================

## 两列 HBoxContainer：左列收缩到内容高并在剩余空间里垂直居中，右列撑满并贴顶。
func test_level_popup_two_columns_centred_and_top_aligned() -> void:
	var host := _host()
	var c := _mount("res://ui/level_select.tscn", host)
	if c == null:
		pending("缺少 level_select.tscn")
		return
	await _settle(18)
	assert_true(c.has_method("_open_popup"), "level_select 应能打开模式弹窗（_open_popup）")
	c.call("_open_popup", 0)
	await _settle(16)

	var boxes: Array = []
	_find_all(c, "HBoxContainer", boxes)
	var two_col: Array = []
	for b in boxes:
		var kids := (b as Node).get_children()
		if kids.size() < 2:
			continue
		var all_vb := true
		for k in kids:
			if not (k is VBoxContainer):
				all_vb = false
				break
		if all_vb:
			two_col.append(b)
	assert_gt(two_col.size(), 0,
		"弹窗里找不到「子节点全是 VBoxContainer」的行 —— 结构变了，本测试需要跟着改")
	if two_col.size() == 0:
		return

	var row: Control = two_col[0]
	var left: Control = row.get_child(0)
	var right: Control = row.get_child(1)
	var rh := row.size.y
	assert_gt(rh, 0.0, "行高为 0，布局还没结算")

	# 左列：收缩居中
	assert_eq(left.size_flags_vertical, Control.SIZE_SHRINK_CENTER,
		"左列（档位列）的 size_flags_vertical 必须是 SHRINK_CENTER，否则它在 VBox 里只会贴顶")
	assert_lt(absf(left.position.y + left.size.y / 2.0 - rh / 2.0), 1.5,
		"左列内容中心 %.1f 与行中心 %.1f 偏差过大 ⇒ 没有垂直居中"
		% [left.position.y + left.size.y / 2.0, rh / 2.0])

	# 右列：撑满贴顶
	assert_eq(right.size_flags_vertical, Control.SIZE_FILL,
		"右列的 size_flags_vertical 必须是 FILL（上对齐）")
	assert_almost_eq(right.size.y, rh, 1.5, "右列高度没有撑满行高")
	assert_almost_eq(right.position.y, 0.0, 0.5, "右列没有贴顶")


# ============================ 主题下拉的完整性 ============================

## 游戏内设置弹窗必须能选到**全部**主题。曾经它自己维护了一份 ["system","dark","light"]，
## 于是 CozyStyle 主题一个都选不到，且当前是 CozyStyle 时下拉是空白的。
func test_settings_popup_offers_every_registered_theme() -> void:
	var host := _host()
	var p := _mount("res://ui/settings_popup.tscn", host)
	if p == null:
		pending("缺少 settings_popup.tscn")
		return
	_show_if_popup(p)
	await _settle(14)
	var opts: Array = []
	_find_all(p, "OptionButton", opts)
	var theme_opt: OptionButton = null
	for o in opts:
		if (o as OptionButton).item_count == ThemeManager.THEME_IDS.size():
			theme_opt = o
			break
	assert_not_null(theme_opt,
		"设置弹窗里没有 item_count == ThemeManager.THEME_IDS.size()（%d）的下拉 —— "
		% ThemeManager.THEME_IDS.size()
		+ "说明它又自己维护了一份主题清单，CozyStyle 主题会在游戏内选不到")
	if theme_opt == null:
		return
	# 每一项都必须有非空文案（空白项 = 玩家看到的下拉是空的）
	for i in theme_opt.item_count:
		assert_ne(theme_opt.get_item_text(i), "",
			"主题下拉第 %d 项文案为空（当前主题 = %s）" % [i, SettingsManager.theme_mode])
	# 当前主题必须能被选中（find 返回 -1 = 回显不上）
	var sel: int = ThemeManager.THEME_IDS.find(SettingsManager.theme_mode)
	assert_gte(sel, 0, "当前主题「%s」不在 THEME_IDS 里" % SettingsManager.theme_mode)
	assert_eq(theme_opt.selected, sel,
		"下拉开着的时候没有回显当前主题（selected=%d，应为 %d）" % [theme_opt.selected, sel])
