# ui_theme.gd —— 统一 UI 样式与悬停微交互（class_name UiTheme）
# 悬停浮动效果：阴影 + 边框变强调色 + 背景稍亮 + pivot 居中的轻微 scale 抬起
# （0.2s 过渡，≤1.15 倍）。
# 注：Godot Container 布局下 translateY 会被布局覆盖，故用 scale 表达「抬起」，
# 视觉等价且不破坏布局。所有取色经 ThemeManager。
#
# 2026-09-29 CozyStyle 改造（几何/阴影部分）：
#   · 圆角 6 → 12（按钮）/ 4 → 8（色标）。CozyStyle 的观感建立在"大圆角 + 低对比"
#     上，旧版的 6px 圆角配粉彩底色会显得又硬又方，是"换了色但不像换了皮"的主因之一。
#   · 常态就给一层软阴影（不再只有 hover 才浮起）——粉彩体系的层次有一半靠阴影撑。
#   · 同时把圆角细分度显式拉满（corner_detail）并开抗锯齿：半径变大后 6 边细分的
#     多边形会被看出来是一圈多边形而不是圆。
#   · pressed 态背景是 accent（实心强调色），字色随之改用 accent_text —— 见下方注释。
#
# 2026-09-29 **二次修订（用户反馈「悬停阴影没有适配、有些突兀」）**：
#   · 阴影的**深度**从这里搬走了 —— 原先两个写死的纯黑常量（α0.10 / α0.22）要服务
#     七套底色，实测同一份 α 在粉彩底上掉 43/255、在深色底上只掉 7/255（差 6 倍）：
#     粉彩主题得到一圈脱色的脏灰，深色主题几乎看不见。
#     现在深度由 `ThemeManager.shadow(base, drop)` **按主题反解**，目标压暗量固定，
#     影色也随主题取（CozyStyle 用该主题自己的深色调）。详见 theme_manager.gd 那一节。
#   · 这里只保留**范围**（模糊半径 / 下移量），且把常态→悬停的跨度收窄
#     （size 8→12 改成 8→10）：换 stylebox 是**瞬时**的，跨度大了就是"影先跳、按钮后长"，
#     正是"弹一下…有个阴影…突兀"的观感来源。
class_name UiTheme

## 阴影的**范围**。深度不在常量里 —— 见 ThemeManager.shadow()。
##
## 常态：贴着一层浅浅的浮起感，让静止的按钮也不像"贴纸"。
const NORMAL_SHADOW_OFFSET := Vector2(0, 2)
const NORMAL_SHADOW_SIZE := 8

## 悬停：只比常态深一档、宽一点点。"抬起一档"还由描边换 accent + 底色提亮 + scale
## 1.03 三条一起表达，阴影不需要独立承担整个层次差。
const HOVER_SHADOW_OFFSET := Vector2(0, 3)
const HOVER_SHADOW_SIZE := 10

## 圆角半径。**不要**用 StyleBoxFlat.expand_margin 去放大投影范围 —— 那会把整个
## stylebox 的绘制矩形撑开，导致相邻控件互相覆盖（已实测踩过）。
const BTN_RADIUS := 12
const SWATCH_RADIUS := 8

## 按钮内边距（左右 / 上下）。
## 中文字形接近方块，且字体行高自带额外留白——沿用主题默认内边距会出现
##「左右贴死文字、上下空荡」的失衡。左右取上下两倍以抵消行高影响，视觉均衡。
const BTN_PAD_X := 16
const BTN_PAD_Y := 8

## **图标按钮**的内容区内边距。必须与文字按钮分开给：
## 文字按钮的 16/8 是给中文方块字留的呼吸位，而图标按钮的内容区**就是图标本身** ——
## 套用 16/8 后内容区缩成 (W−32)×(H−16)，40×40 的齿轮按钮只剩 **8×8**，
## `expand_icon` 于是老老实实把图标按 8px 画出来（2026-09-29 实测复现：选关页右上角的
## 齿轮/书本、对局页的毛笔，三个图标全都缩成一个小方块）。
## 取 9：40×40 → 22×22，48×48 → 30×30，与 12px 圆角 + 1px 描边的比例配得上。
const ICON_PAD := 9


## 统一圆角，顺带把细分度与抗锯齿一次设好（见文件头说明）。
static func _round(sb: StyleBoxFlat, radius: int) -> void:
	sb.set_corner_radius_all(radius)
	sb.corner_detail = clampi(radius + 2, 8, 20)
	sb.anti_aliasing = true


## 统一按钮样式 + 悬停浮动（scale 1.03 ≈ 2px 抬起感）。
## pad_x / pad_y 可覆盖：图标按钮走 style_icon_button（见该函数与 ICON_PAD 的说明）。
static func style_button(btn: Button, pad_x: int = BTN_PAD_X, pad_y: int = BTN_PAD_Y) -> void:
	var normal := StyleBoxFlat.new()
	_set_pad(normal, pad_x, pad_y)
	normal.bg_color = ThemeManager.card()
	_round(normal, BTN_RADIUS)
	normal.set_border_width_all(1)
	normal.border_color = ThemeManager.grid_line()
	normal.shadow_color = ThemeManager.shadow(ThemeManager.bg())
	normal.shadow_size = NORMAL_SHADOW_SIZE
	normal.shadow_offset = NORMAL_SHADOW_OFFSET
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_color_override("font_color", ThemeManager.text())

	var hover := StyleBoxFlat.new()
	_set_pad(hover, pad_x, pad_y)
	hover.bg_color = ThemeManager.card().lightened(0.06)
	_round(hover, BTN_RADIUS)
	hover.set_border_width_all(1)
	hover.border_color = ThemeManager.accent()
	hover.shadow_color = ThemeManager.shadow(ThemeManager.bg(), ThemeManager.SHADOW_DROP_HOVER)
	hover.shadow_size = HOVER_SHADOW_SIZE
	hover.shadow_offset = HOVER_SHADOW_OFFSET
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_color_override("font_hover_color", ThemeManager.text())

	var pressed := StyleBoxFlat.new()
	_set_pad(pressed, pad_x, pad_y)
	pressed.bg_color = ThemeManager.accent()
	_round(pressed, BTN_RADIUS)
	pressed.set_border_width_all(1)
	pressed.border_color = ThemeManager.accent()
	btn.add_theme_stylebox_override("pressed", pressed)
	# 按下态背景换成了**实心 accent**，字色就必须跟着换 accent_text。
	# 原先这里沿用 text()：深色主题下 accent 是深蓝、text 是近白，勉强能看；
	# 但浅色主题 accent=#2D7BB0 配 text=#232323 只有 1.9:1 —— 一个从旧版就存在、
	# 一直没人发现的无障碍缺陷（深色主题把它盖住了）。CozyStyle 五套粉彩全是浅底，
	# 再不改就是五个主题一起踩。accent_text 是成对算出来的（每个主题都 ≥4.5:1）。
	btn.add_theme_color_override("font_pressed_color", ThemeManager.accent_text())

	# 键盘焦点样式（2026-09-25 无障碍审计）：与 hover 同款但描边**更粗** —— 焦点必须
	# 比悬停更显眼（键盘用户全靠它定位）。此前没有 focus 样式 ⇒ 聚焦时会落到引擎默认
	# 焦点框（浅色细线，与项目深色主题格格不入）。
	var focus_sb := StyleBoxFlat.new()
	_set_pad(focus_sb, pad_x, pad_y)
	focus_sb.bg_color = ThemeManager.card().lightened(0.06)
	_round(focus_sb, BTN_RADIUS)
	focus_sb.set_border_width_all(2)
	focus_sb.border_color = ThemeManager.accent()
	# 【2026-09-29 补】focus 以前**没有阴影**，而 hover 有 —— 于是用 Tab 把焦点移到
	# 某个按钮上，阴影会"啪"地出现/消失，同一个悬停语义两种观感。与 hover 取同一档。
	focus_sb.shadow_color = ThemeManager.shadow(ThemeManager.bg(), ThemeManager.SHADOW_DROP_HOVER)
	focus_sb.shadow_size = HOVER_SHADOW_SIZE
	focus_sb.shadow_offset = HOVER_SHADOW_OFFSET
	btn.add_theme_stylebox_override("focus", focus_sb)
	btn.add_theme_color_override("font_focus_color", ThemeManager.text())

	bind_hover(btn, 1.03)


## 图标按钮（按钮上只有 icon、没有 text，配 expand_icon）：
## 与 style_button 同一套颜色/圆角/阴影/悬停，只把内边距换成**对称的图标内边距**。
## 不这么做就会踩 ICON_PAD 注释里那个坑（图标被内容区压成 8px）。
static func style_icon_button(btn: Button) -> void:
	style_button(btn, ICON_PAD, ICON_PAD)


## 应用内边距（normal/hover/pressed/focus 四态共用，避免切换时按钮尺寸跳动）。
static func _set_pad(sb: StyleBoxFlat, pad_x: int, pad_y: int) -> void:
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y


## 色标（圆形/方形色块）：悬停 scale 1.15 放大，不浮动；选中态 accent 边框。
static func style_swatch(sw: Button, color: Color, selected: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	_round(sb, SWATCH_RADIUS)
	if selected:
		sb.set_border_width_all(2)
		sb.border_color = ThemeManager.accent()
	else:
		sb.set_border_width_all(1)
		sb.border_color = ThemeManager.grid_line()
	sb.shadow_color = ThemeManager.shadow(ThemeManager.bg())
	sb.shadow_size = NORMAL_SHADOW_SIZE
	sb.shadow_offset = NORMAL_SHADOW_OFFSET
	sw.add_theme_stylebox_override("normal", sb)
	sw.add_theme_stylebox_override("hover", sb)
	sw.add_theme_stylebox_override("pressed", sb)
	sw.add_theme_stylebox_override("focus", sb)
	bind_hover(sw, 1.15)


## 绑定 hover 抬起：进入 scale 到目标，离开回 1.0（0.2s ease-out，不超过 0.3s）。
static func bind_hover(control: Control, scale_to: float) -> void:
	if control.has_meta("_ui_hover_lift"):
		return
	control.set_meta("_ui_hover_lift", true)
	control.mouse_entered.connect(func(): _lift_to(control, scale_to))
	control.mouse_exited.connect(func(): _lift_to(control, 1.0))


## 两点修正（原实现的真实缺陷）：
##   ① 每次进出都 create_tween()：快速划过会留下多个同目标同属性的 tween 同时驱动 scale，
##      谁后写谁生效 → 抖动甚至卡在非 1.0 的缩放上。现先 kill 掉本控件上的旧 tween 再开新的。
##   ② pivot_offset 原先只在 mouse_entered 那一刻按当时 size 取；换页/改字号后布局一变，
##      缩放就不再绕中心（表现为斜向漂移）。改为动画开始时才取当前 size。
static func _lift_to(control: Control, scale_to: float) -> void:
	if not is_instance_valid(control):
		return
	# get_meta 在键不存在时会打印 ERROR（即使传了 default）→ 先 has_meta 判断，
	# 否则调试器每次首次悬停都刷一条「no 'meta' values with the key '_ui_hover_tween'」。
	if control.has_meta("_ui_hover_tween"):
		var old: Tween = control.get_meta("_ui_hover_tween")
		if old != null and old.is_valid():
			old.kill()
	control.pivot_offset = control.size * 0.5
	var tw := control.create_tween()
	tw.set_trans(Tween.TRANS_QUAD)
	tw.set_ease(Tween.EASE_OUT)
	tw.tween_property(control, "scale", Vector2(scale_to, scale_to), 0.2)
	control.set_meta("_ui_hover_tween", tw)
