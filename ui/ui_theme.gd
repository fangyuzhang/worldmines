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
## 【2026-09-30 浮动卡片化】offset/size 双双加深一档（参考 cozy 数独的动作钮：
## 静止就有"拿起来"的厚度），深度仍由 ThemeManager.shadow() 按主题反解。
const NORMAL_SHADOW_OFFSET := Vector2(0, 3)
const NORMAL_SHADOW_SIZE := 10

## 【2026-10-01 抖动修复 ③】阴影几何（offset / size）**四态共用同一组值**，不再逐态调整。
##
## 为什么必须相同：stylebox 的切换是**瞬时**的——Godot 的 `theme_override_styles` 是整体
## 替换，没有过渡（想平滑只能逐帧 tween StyleBoxFlat 的属性，代价与复杂度都不合适）。
## 于是"悬停时影子宽 1px / 按下时影子收到脚边"这类**几何**差异，都会在切态那一帧
## "啪"地跳一下；而同一时刻 scale 正在 0.2s 平滑播放 —— 两者不同步，人眼就读成抖动
##（2026-09-30 已把跨度从 (0,3)/10 → (0,1)/4 缩过一轮，仍不足以消除）。
##
## 现在层次差全部交给**不会瞬变或瞬变也自然**的手段：
##   · scale（连续动画）
##   · 底色提亮 / 描边换 accent（纯颜色切换，读起来是"变色"而非"抖"）
##   · 影色深浅（同上，颜色不同、几何相同）
const HOVER_SHADOW_OFFSET := NORMAL_SHADOW_OFFSET
const HOVER_SHADOW_SIZE := NORMAL_SHADOW_SIZE
const PRESSED_SHADOW_OFFSET := NORMAL_SHADOW_OFFSET
const PRESSED_SHADOW_SIZE := NORMAL_SHADOW_SIZE

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
	# 【2026-10-01 抖动修复 ④（根因）】normal / hover / pressed **共用这一份** stylebox。
	# 换 stylebox 是瞬时的（Godot 主题项整体替换），与 0.2s 的缩放不同步 ⇒ 实机读成抖动；
	# 状态差异改由 bind_state_colors 登记的**颜色渐变**表达（见 META_STATE_COLORS 的说明）。
	var sb := StyleBoxFlat.new()
	_set_pad(sb, pad_x, pad_y)
	_round(sb, BTN_RADIUS)
	sb.set_border_width_all(1)
	sb.bg_color = ThemeManager.card()
	sb.border_color = ThemeManager.grid_line()
	sb.shadow_color = ThemeManager.shadow(ThemeManager.bg())
	sb.shadow_size = NORMAL_SHADOW_SIZE
	sb.shadow_offset = NORMAL_SHADOW_OFFSET
	for state in ["normal", "hover", "pressed"]:
		btn.add_theme_stylebox_override(state, sb)
	# 三档颜色（下标 = PHASE_*）：底色提亮 / 加深、描边换 accent、影色深一档——全部**渐变**。
	bind_state_colors(btn, {
		"bg": [ThemeManager.card(),
				ThemeManager.card().lightened(0.06),
				ThemeManager.card().darkened(0.10)],
		"border": [ThemeManager.grid_line(), ThemeManager.accent(), ThemeManager.accent()],
		"shadow": [ThemeManager.shadow(ThemeManager.bg()),
				ThemeManager.shadow(ThemeManager.bg(), ThemeManager.SHADOW_DROP_HOVER),
				ThemeManager.shadow(ThemeManager.bg(), ThemeManager.SHADOW_DROP_HOVER)],
	})
	# 字色三态同值：按下不再换实心 accent 底（那会连字体色一起瞬变），故无需随态变色。
	# 【历史】原 pressed 是实心 accent + font_pressed_color=accent_text()，为修一处无障碍缺陷
	#（浅色主题 accent×text 仅 1.9:1）。现在按下底色是 card 深一档、字始终是 text()，问题不复存在。
	btn.add_theme_color_override("font_color", ThemeManager.text())
	btn.add_theme_color_override("font_hover_color", ThemeManager.text())
	btn.add_theme_color_override("font_pressed_color", ThemeManager.text())
	btn.add_theme_color_override("font_focus_color", ThemeManager.text())

	# 键盘焦点样式（2026-09-25 无障碍审计）：单独一份、描边**更粗** —— 焦点必须比悬停更显眼
	#（键盘用户全靠它定位）。它不参与鼠标悬停路径，故不受抖动修复影响，可保留独立样式。
	var focus_sb := StyleBoxFlat.new()
	_set_pad(focus_sb, pad_x, pad_y)
	focus_sb.bg_color = ThemeManager.card().lightened(0.06)
	_round(focus_sb, BTN_RADIUS)
	focus_sb.set_border_width_all(2)
	focus_sb.border_color = ThemeManager.accent()
	# 【2026-09-29 补】focus 以前**没有阴影**，而 hover 有 —— 于是用 Tab 把焦点移到
	# 某个按钮上，阴影会"啪"地出现/消失，同一个悬停语义两种观感。与常态取同一档。
	# 【2026-10-01 修正】影色不再取"悬停加深档"：三态共份后静态基准是**常态档**
	#（悬停/按下的加深由 tween 动态给出），focus 若用加深档就会在 Tab 聚焦瞬间突变。
	# 焦点的显眼度由「底亮 12% + 2px 描边」承担，足够了。
	focus_sb.shadow_color = ThemeManager.shadow(ThemeManager.bg())
	focus_sb.shadow_size = NORMAL_SHADOW_SIZE
	focus_sb.shadow_offset = NORMAL_SHADOW_OFFSET
	btn.add_theme_stylebox_override("focus", focus_sb)

	bind_hover(btn, 1.03)
	attach_press_feedback(btn)


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
	attach_press_feedback(sw)   # 【2026-09-30】色标也是可点元素，统一按压回弹


## 【2026-09-30 浮动卡片化】按压回弹（所有按钮及可点击元素统一）：
##   按下 → scale 缩到 0.96（0.06s，快而短 = "按下去"）；
##   松开 → 回弹到悬停高度（0.22s）。
## 【2026-10-01 抖动修复 ②】松开原先用 TRANS_BACK（"越过目标再落回"的过冲），实机被
##   感知为抖动——鼠标仍悬停时目标是 1.03 而不是 1.0，距离翻倍、过冲更明显。
##   现改为与其它动画一致的 QUAD EASE_OUT：单调靠近目标，无过冲。
## 与 hover 抬起共用同一个 tween 槽（_ui_hover_tween）——两套动画互杀，不会打架。
## pivot 每次动画开始时取当前 size（换页/改字号后仍绕中心，同 _lift_to 的修正）。
## 键盘激活（空格/回车）同样触发 button_down/up，键盘用户得到同一份反馈。
const PRESS_SCALE := 0.96
const PRESS_DOWN_SEC := 0.06
const PRESS_RELEASE_SEC := 0.22

static func attach_press_feedback(btn: BaseButton) -> void:
	if btn.has_meta("_ui_press_fx"):
		return
	btn.set_meta("_ui_press_fx", true)
	btn.button_down.connect(func(): _press_down(btn))
	btn.button_up.connect(func(): _press_release(btn))


static func _press_down(btn: BaseButton) -> void:
	if not is_instance_valid(btn):
		return
	_kill_ui_tween(btn)
	btn.pivot_offset = btn.size * 0.5
	var tw := btn.create_tween()
	tw.set_trans(Tween.TRANS_QUAD)
	tw.set_ease(Tween.EASE_OUT)
	tw.tween_property(btn, "scale", Vector2(PRESS_SCALE, PRESS_SCALE), PRESS_DOWN_SEC)
	_tween_state_colors(btn, tw, PHASE_PRESS, PRESS_DOWN_SEC)   # 按下档颜色（渐变，见修复 ④）
	btn.set_meta("_ui_hover_tween", tw)
	btn.set_meta("_ui_lift_target", PRESS_SCALE)   # 目标记录与去重逻辑保持同步


static func _press_release(btn: BaseButton) -> void:
	if not is_instance_valid(btn):
		return
	_kill_ui_tween(btn)
	btn.pivot_offset = btn.size * 0.5
	# 【2026-09-30 抖动修复 ③】松开后鼠标仍悬停 → 直接回到抬起高度（不塌回 1.0 再
	# 等下一次 entered 才抬起——那个"塌了又跳"正是按压后悬停抖感的来源）。
	var rest: float = 1.0
	if btn.is_hovered():
		rest = float(btn.get_meta("_ui_hover_scale", 1.03))
	var tw := btn.create_tween()
	# 【2026-10-01 抖动修复 ②】不用 TRANS_BACK：过冲（越过目标再落回）被实机反馈为抖动，
	# 且鼠标仍悬停时 rest=1.03 使过冲量更大。QUAD EASE_OUT 单调靠近目标，与 hover 一致。
	tw.set_trans(Tween.TRANS_QUAD)
	tw.set_ease(Tween.EASE_OUT)
	tw.tween_property(btn, "scale", Vector2(rest, rest), PRESS_RELEASE_SEC)
	# 颜色随缩放一起回弹到「悬停档」（鼠标仍在上）或「常态档」，同一时间轴（修复 ④）
	_tween_state_colors(btn, tw, PHASE_HOVER if btn.is_hovered() else PHASE_BASE, PRESS_RELEASE_SEC)
	btn.set_meta("_ui_hover_tween", tw)
	btn.set_meta("_ui_lift_target", rest)


static func _kill_ui_tween(control: Control) -> void:
	if control.has_meta("_ui_hover_tween"):
		var old: Tween = control.get_meta("_ui_hover_tween")
		if old != null and old.is_valid():
			old.kill()


## 【2026-10-01 抖动修复 ④（根因）】状态**不换 stylebox**：normal / hover / pressed 共用同一份，
## 状态差异全部改成**颜色 tween**（与缩放在同一根时间轴上，节奏天然同步）。
##
## 为什么这是根因 —— 实机线索是「所有按钮都抖，唯独棋盘格子不抖」，而棋盘格子恰好是全项目
## 唯一「normal/hover/pressed 共用一份 stylebox」的控件（level_select._style_tile）。
## 换 stylebox 是**瞬时**的（Godot 主题项整体替换、没有过渡）：悬停那一刻颜色 / 描边 / 影色
## 一起跳，而 scale 还在 0.2s 平滑放大——两者不同步，实机读感就是「上升过程中抖」。
## 2026-09-30 与 2026-10-01 前两轮只收敛了阴影**几何**（size/offset），没动"换 stylebox"这个
## 动作本身，所以抖动仍在。
##
## focus 仍然单独一份：键盘聚焦不在鼠标悬停路径上，且需要更粗的描边（无障碍），互不影响。
const META_STATE_COLORS := "_ui_state_colors"
const PHASE_BASE := 0
const PHASE_HOVER := 1
const PHASE_PRESS := 2


## 登记三档颜色（配合「多态共用一份 stylebox」）。colors 的键：
##   bg / border / shadow → [常态, 悬停, 按下]；数组短于 3 时末位色向后沿用（如卡片无影）。
static func bind_state_colors(btn: Button, colors: Dictionary) -> void:
	btn.set_meta(META_STATE_COLORS, colors)


## 把按钮 stylebox 的颜色 tween 到目标档，**挂在调用方的 tween 上**（共享时间轴）。
## 取 stylebox 的入口固定是 "normal" 槽——normal/hover/pressed 共用同一份，它就是"当前那份"。
static func _tween_state_colors(control: Control, tw: Tween, phase: int, sec: float) -> void:
	if not control.has_meta(META_STATE_COLORS):
		return
	var sb := control.get_theme_stylebox("normal") as StyleBoxFlat
	if sb == null:
		return
	var colors: Dictionary = control.get_meta(META_STATE_COLORS)
	for key: String in ["bg", "border", "shadow"]:
		var arr: Array = colors.get(key, [])
		if arr.is_empty():
			continue
		var target: Color = arr[mini(phase, arr.size() - 1)]
		tw.parallel().tween_property(sb, "%s_color" % key, target, sec)


## 绑定 hover 抬起：进入 scale 到目标，离开回 1.0（0.2s ease-out，不超过 0.3s）。
static func bind_hover(control: Control, scale_to: float) -> void:
	if control.has_meta("_ui_hover_lift"):
		return
	control.set_meta("_ui_hover_lift", true)
	control.set_meta("_ui_hover_scale", scale_to)   # 按压释放回弹的目标高度（悬停感知用）
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
	# 【2026-09-30 抖动修复 ②】按住期间（含按住时鼠标滑到边缘"出界"）不被拉回——
	# 按下缩到 0.96 后命中区变小，边缘的鼠标会触发 exited → 抬回 → 又"入界" → 抖动循环。
	if scale_to > 0.99 and control is BaseButton and (control as BaseButton).button_pressed:
		return
	# 【2026-09-30 抖动修复 ①】同目标去重：tween 已经在往同目标走就不杀不重建
	#（重复 create/kill 是微抖来源；快速滑动相邻按钮时尤其明显）。
	# 【2026-10-01 修正】原实现读的是 **tween 上**的 `_ui_lift_target`，而下面写入的是
	# **控件上**的 —— 两者不是一个对象，`get_meta` 每次都回落到默认值，于是去重**从未
	# 生效**（注释写了、逻辑没跑）。改为从控件读目标值。
	if control.has_meta("_ui_hover_tween"):
		var cur: Tween = control.get_meta("_ui_hover_tween")
		var cur_target: float = float(control.get_meta("_ui_lift_target", -9.9))
		if cur != null and cur.is_valid() and cur_target == scale_to:
			return
	# 记录本次目标（同目标去重用）。
	control.set_meta("_ui_lift_target", scale_to)
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
	# 颜色与缩放**同一根时间轴**（抖动修复 ④：状态差异全靠渐变，不再换 stylebox）
	_tween_state_colors(control, tw, PHASE_HOVER if scale_to > 0.99 else PHASE_BASE, 0.2)
	control.set_meta("_ui_hover_tween", tw)
