# tool_shell.gd —— 全屏工具面板外壳（成就墙 / 解谜者画像 / 教学树 / 创作中心共用）
#
# 为什么抽出来：这四个面板的结构完全相同（遮罩 → 主题底板 → 标题行 + 关闭 → 可滚动正文），
# 复制四份必然出现「只有其中一个忘了加底板 ⇒ 下层文字透上来」——教程覆盖层当年正是这么踩的
#（见 ui/tutorial_overlay.gd 的 2026-10-02 注释：只有遮罩没有底板，毛玻璃背景下的文字互相叠）。
#
# ⚠️ 刻意不写 class_name（坑表 #26）。调用方：const Shell := preload("res://ui/tool_shell.gd")。
extends RefCounted


const OVERLAY_META := "tool_overlay"


## 同宿主只留一层：先把已有工具面板移出场景树（连点入口不叠层）。
static func close_existing(host: Node) -> void:
	if host == null:
		return
	for c in host.get_children():
		if c.has_meta(OVERLAY_META) and is_instance_valid(c):
			host.remove_child(c)
			c.queue_free()


## 建一层全屏模态。返回 {"root": Control, "body": VBoxContainer, "close": Button}；
## host 不在树里时返回 {}（调用方必须判空，不要硬 add_child）。
static func build(host: Control, title: String, subtitle: String = "") -> Dictionary:
	if host == null or not host.is_inside_tree():
		return {}
	close_existing(host)

	var root := Control.new()
	root.name = "ToolOverlay"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.set_meta(OVERLAY_META, true)
	host.add_child(root)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 32)
	margin.add_theme_constant_override("margin_bottom", 32)
	root.add_child(margin)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(panel)

	var inner := MarginContainer.new()
	inner.add_theme_constant_override("margin_left", 16)
	inner.add_theme_constant_override("margin_right", 16)
	inner.add_theme_constant_override("margin_top", 12)
	inner.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(inner)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	inner.add_child(vbox)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	vbox.add_child(head)

	var title_lb := Label.new()
	title_lb.text = title
	title_lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lb.add_theme_font_size_override("font_size", 24)
	head.add_child(title_lb)

	var close := Button.new()
	close.name = "ToolClose"
	close.text = "关闭"
	close.focus_mode = Control.FOCUS_ALL
	close.set_meta("tool_close", true)
	UiTheme.style_button(close)
	head.add_child(close)

	var sub: Label = null
	if subtitle != "":
		sub = Label.new()
		sub.name = "ToolSubtitle"
		sub.text = subtitle
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub.add_theme_font_size_override("font_size", 14)
		vbox.add_child(sub)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var body := VBoxContainer.new()
	body.name = "ToolBody"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	scroll.add_child(body)

	close.pressed.connect(func(): root.queue_free())
	return {"root": root, "body": body, "close": close, "subtitle": sub}


## 一节标题（组名 + 右侧计数）。返回一条横向条。
static func section_header(name: String, desc: String, right: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var lb := Label.new()
	lb.text = name
	lb.add_theme_font_size_override("font_size", 19)
	row.add_child(lb)
	var d := Label.new()
	d.text = desc
	d.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	d.add_theme_font_size_override("font_size", 13)
	row.add_child(d)
	var r := Label.new()
	r.text = right
	r.add_theme_font_size_override("font_size", 14)
	row.add_child(r)
	row.set_meta("section_header", true)
	return row


## 一行说明 / 空态文案。
static func note(text: String) -> Label:
	var lb := Label.new()
	lb.text = text
	lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lb.add_theme_font_size_override("font_size", 14)
	return lb


## 给控件套一层内边距（GridContainer 里的卡片用）。
static func padded(node: Control, all: int = 10) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", all)
	m.add_theme_constant_override("margin_right", all)
	m.add_theme_constant_override("margin_top", all)
	m.add_theme_constant_override("margin_bottom", all)
	m.add_child(node)
	return m
