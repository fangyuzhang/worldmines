# hud.gd —— 顶栏（雷数 / 计时 / 教程 / 提示）+ 左右两列（关卡列表 / 暂停·撤销·设置）
#
# 文案 §8.5：「雷数」+ 数字（允许为负）；「时间」+ MM:SS。
#
# 交互修正（原实现的三个真实问题）：
#   ① 「返回 / 返回菜单」两个按钮挨在一起且只差两个字，误点即 SaveCoordinator.clear()
#      ——现改为语义明确的「关卡列表 / 主菜单」，并对局进行中二次确认；
#   ② 「提示」按钮曾显示充能百分比（2026-09-28 充能机制退役：每次只给 ≤2 格、不消耗）；
#   ③ 旗数每帧全盘遍历（O(格子数)/帧）——改为按 cell_state_changed 失效的缓存。
#
# 2026-09-29 **形态改造**（用户授权「可以改变位置与形态」）：
#   · 顶栏从「两段纯文字 + 两个文字按钮混排」改成「图标 + 数字」的**读数组**：
#     ⦿10　📖　⏱00:00 —— 雷用图标、时间用图标，数字不再拖「剩余雷数 / 时间」两个
#     固定前缀（语义挪进 tooltip）。原样混排的问题是同一行里 28px 的裸 Label 与
#     16px 的按钮胶囊**高度、字重、底色全不一样**，看起来像三样东西拼在一起。
#   · 「教程」从文字按钮改成**书本图标**（与选关页右上角同一本书，见 ui/ui_icons.gd）。
#   · 「提示」从顶栏文字按钮改成**灯泡图标**，锚到右上角，与「毛笔」组成右上工具簇
#     ——原来它孤零零悬在右上角而毛笔悬在右中偏上，两边都不属于任何一组。
#     位置契约（B9）随之从「前一个兄弟是雷数 Label」改成「前一个兄弟是雷数读数组」。
extends Control

# 图标走 preload 而非 class_name 引用（headless 下新全局类不在 .godot 缓存里，见坑表 #26）
const Icons := preload("res://ui/ui_icons.gd")
# 教程覆盖层用 preload 而非 class_name 引用（headless 下新全局类不在 .godot 缓存里，见坑表 #26）
const TutorialOverlayScript := preload("res://ui/tutorial_overlay.gd")

## 顶栏高度。顶栏内容（读数组 / 图标按钮）都在这条带里垂直居中；
## board_view 的分色雷数面板从 62 起画，就是为了紧贴这条带。
const TOP_BAR_H := 64.0

## 顶栏 / 右上工具簇的图标按钮边长。与 UiTheme.ICON_PAD 配套：40 − 2×9 = 22px 内容区，
## 32×32 的 SVG 缩到 22px 依然认得出造型（同一口径已在选关页验证过）。
const ICON_BTN_SIZE := 40.0

## 右上工具簇：与屏幕右缘的距离、两枚图标之间的间距。
## 「提示」（本文件）与「毛笔」（ui/drawing_toolbar.gd）是两个场景，靠这组常量对齐 ——
## 两处都从右缘 -24 起排，改这里必须同步改 drawing_toolbar（那里有注释互相指）。
const TOOLBAR_EDGE := 24.0
const TOOLBAR_GAP := 8.0

var _mines_label: Label
var _time_label: Label
var _deducible_label: Label
var _hint_btn: Button
var _hint_menu: PopupMenu
var _tut_btn: Button
var _pause_btn: Button
## 连接透镜按钮（**只在真的存在错觉的盘上装**，见 _sync_lens_button）：
## 普通棋盘进场时它是 null ⇒ 右列仍是「提示 / 撤销 / 暂停」三枚，不多一枚按了没反应的死按钮。
var _lens_btn: Button = null
## 「摊平 / 折起来」开关（**只在折叠盘上装**，见 _sync_fold_button）：普通棋盘进场时是 null。
var _fold_btn: Button = null
var _pause_icon_shown_paused := false
var _settings_popup: PopupPanel
## 右上单排图标簇里的「设置」齿轮（配置类图标，对齐 CozySudoku 顶栏右侧的齿轮位）。
var _settings_btn: Button
## 换肤（2026-09-29）：右上工具簇的调色板按钮。【2026-09-30 常驻组件化】
## 按钮 + 主题面板 + ThemeManager 联动整体抽到 ui/theme_picker_button.gd
##（HUD 与选关页共用同一组件，单一事实源），HUD 只持引用定位。
var _skin_btn: Button

## 顶栏按钮排。2026-09-29 起只装**左侧读数组 + 教程入口**（提示已挪到右上工具簇）。
var _box: HFlowContainer
## 雷数 / 时间读数的「图标 + 数字」组（B9 位置契约的锚点：教程紧跟在雷数组之后）。
var _mines_box: HBoxContainer
var _time_box: HBoxContainer
var _mines_icon: TextureRect
var _time_icon: TextureRect
## 右上工具簇里的图标按钮（提示 / —— 毛笔在另一个场景）。统一样式入口。
var _icon_buttons: Array[Button] = []
## 左右两列（2026-09-28）。**2026-09-30 向 CozySudoku 靠拢后左列取消**（「关卡列表」移到左上角），
## 只保留**右侧对局工具列**（提示 / 撤销 / 暂停）。
var _right_col: VBoxContainer
## 左上角主操作：关卡列表（顶栏排第一项，对齐 CozySudoku 的「新游戏」位）。
var _nav_btn: Button
## 侧列全部按钮（主题样式统一入口；容器本身 IGNORE 不吃事件，故样式按按钮收集）。
var _side_buttons: Array[Button] = []
## 侧列空闲透明度：竖列压在棋盘两侧，全不透明会挡视线；鼠标进入任一侧列按钮 → 整列 1.0。
const SIDE_COL_IDLE_ALPHA := 0.55
## 侧列保留宽度（**对局棋盘布局必须扣除它**，见 board_view._layout 的 avail_w）：
## 侧列浮在棋盘两侧，不给棋盘让位的话边缘格子会被按钮盖住 —— 棋盘原占满 vp.x−48，
## 侧列各占约 96px ⇒ 左右各约半格落在按钮下（点不到、也看不清）。值 = 按钮宽 84 +
## 外边距 12 + 与棋盘的间隙 8。**改侧列尺寸必须同步改它**（board_view 直接引用本常量）。
const SIDE_COL_RESERVE := 104.0
var _last_shown_sec: int = -1
var _flag_cache: int = -1
# 「可断定格数」0.5s 节流缓存：推导含 CP-SAT 全盘哈希，终极模式常开时每帧全算白付性能
var _deducible_cache: int = 0
var _deducible_at_ms: int = -100000


func _ready() -> void:
	add_to_group("themed")
	ThemeManager.theme_changed.connect(_on_theme_changed)
	# 2026-09-30（向 CozySudoku 靠拢）：顶栏左上角 = 关卡列表（主操作）；
	# 顶栏 = ⦿雷数 · 📖教程 · ⏱时间 · 可断定；右上**单排图标** = ⚙设置 · 🎨换肤
	# （+ 另一场景的 🖌毛笔）；右侧 = **对局工具列**（💡提示 · ↩撤销 · ⏸暂停）。
	# 根节点铺满全屏以承载两列，但 **mouse_filter = IGNORE**：空白处不吃点击，棋盘（下层）
	# 照常可点；侧列容器同理（IGNORE），只有按钮自己消费点击（棋盘走 _gui_input，
	# 上层按钮会先消费 —— 不会出现「点按钮同时翻了一格」）。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# ---------- 顶栏 ----------
	# HFlowContainer（2026-09-25 审计）：窄窗口下按钮排自动换行 —— 此前 HBoxContainer
	# 会把右端按钮推出屏外（无 clip，直接不可见、不可点）。窗口最小尺寸（1024×576）已挡
	# 住主要场景，这里再兜一层。
	_box = HFlowContainer.new()
	_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_box.offset_bottom = TOP_BAR_H   # 明确顶栏高度，避免 28px 字体溢出顶部被裁剪
	_box.offset_left = 24
	_box.offset_right = -24
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_theme_constant_override("separation", 18)
	add_child(_box)

	# ---------- 左上角：关卡列表（对齐 CozySudoku「新游戏」的主操作位）----------
	# CozySudoku 把主操作放**左上角**。本项目对局内的主操作 = 离开 / 换关，故作为顶栏排
	# 的**第一项**（= 左上角）。2026-09-30 之前它是「左中列」里的一个独立按钮，随
	# 「向 CozySudoku 靠拢」移到左上角；左中列随之取消（棋盘左侧让位保留，留给分色面板/宠物）。
	_nav_btn = Button.new()
	_nav_btn.text = "关卡列表"
	_nav_btn.tooltip_text = "保存进度并返回关卡选择"
	_nav_btn.focus_mode = Control.FOCUS_ALL
	_nav_btn.custom_minimum_size = Vector2(120, 40)
	_nav_btn.pressed.connect(func():
		GameSession.save_now()
		get_tree().change_scene_to_file("res://ui/level_select.tscn"))
	# 试玩回程（2026-10-02 用户反馈）：从编辑器点「试玩」进来时 `GameSession.playtest_return` 非空 ⇒
	# 顶栏多一个「回编辑器」，放在「关卡列表」**之前**（试玩时的主操作是"回去接着改"，不是"去选关页"）。
	# **正式发售的游戏里它永远是空串** ⇒ 普通玩家不会看到"编辑器"字样
	#（这是 2026-09-23「不在游戏 HUD 加返回编辑器」决策的例外：只对从编辑器点进来的试玩生效）。
	if str(GameSession.playtest_return) != "":
		var back_ed := Button.new()
		back_ed.text = "回编辑器"
		back_ed.tooltip_text = "结束试玩，回到关卡编辑器（进度已存，最后几笔改动也保住了）"
		back_ed.focus_mode = Control.FOCUS_ALL
		back_ed.custom_minimum_size = Vector2(120, 40)
		var target := str(GameSession.playtest_return)
		back_ed.pressed.connect(func():
			GameSession.save_now()
			GameSession.playtest_return = ""
			get_tree().change_scene_to_file(target))
		_box.add_child(back_ed)
		# 试玩专用（文档 §7「检查进度（标记插错的旗）」）：作者在试玩里核对"这关到底通没通"。
		# 与「回编辑器」同一个闸（`playtest_return` 非空）⇒ 正式游戏里这两个按钮不存在，
		# 玩家不可能靠它把雷位看出来（对局中判旗的对错 = 泄露雷位）。
		var check_btn := Button.new()
		check_btn.text = "检查进度"
		check_btn.tooltip_text = "把插错的旗画上红叉（试玩专用：作者核对进度用，正式游戏里没有这个按钮）"
		check_btn.focus_mode = Control.FOCUS_ALL
		check_btn.custom_minimum_size = Vector2(120, 40)
		check_btn.pressed.connect(func(): GameSession.progress_check_requested.emit(true))
		_box.add_child(check_btn)
		var clear_btn := Button.new()
		clear_btn.text = "收起标记"
		clear_btn.tooltip_text = "擦掉上一步画的红叉（盘面一变也会自动擦掉，免得看着过期的标记做判断）"
		clear_btn.focus_mode = Control.FOCUS_ALL
		clear_btn.custom_minimum_size = Vector2(120, 40)
		clear_btn.pressed.connect(func(): GameSession.progress_check_requested.emit(false))
		_box.add_child(clear_btn)
	_box.add_child(_nav_btn)

	# 雷数读数（⦿ + 数字）。语义「剩余 = 总雷数 − 已插旗」挪进 tooltip —— 2026-09-25
	# 审计曾特意把文案从「雷数」改成「剩余雷数」，那条**语义**没丢，只是不再占一行字。
	_mines_box = _make_readout(Icons.mine(), 28)
	_box.add_child(_mines_box)
	_mines_icon = _mines_box.get_child(0) as TextureRect
	_mines_label = _mines_box.get_child(1) as Label
	_mines_box.tooltip_text = "剩余雷数 = 总雷数 − 已插旗（旗插多了会变红并显示负数）"

	# 教程入口（2026-09-23 用户决策）：从主菜单总入口改为**上下文相关**——这里放在
	# **左上角**（紧贴「雷数」读数组），点击看**当前变体**的教程。
	# 图标与选关页右上角的「规则图鉴」是**同一本书**（ui/ui_icons.gd::book）——
	# 两处各画一份必然漂移，而漂移只能靠截图偶然发现。
	_tut_btn = _add_icon_button(Icons.book(), "教程：当前变体的玩法规则",
		func(): _open_tutorial())
	_tut_btn.name = "TutorialBtn"
	_tut_btn.set_meta("tutorial_btn", true)   # 测试 / 调试可据此定位（图标按钮没有文字可找）
	# `_add_icon_button` 只造按钮、不自动入树（设置/教程各自决定挂到哪），教程这里手动入列并
	# 按「雷数组」的相对位置回插（不写死索引 1 的另一层含义：将来雷数前面再加元素时不会漂）。
	_box.add_child(_tut_btn)
	_box.move_child(_tut_btn, _mines_box.get_index() + 1)

	# 时间读数（⏱ + MM:SS）
	_time_box = _make_readout(Icons.clock(), 28)
	_box.add_child(_time_box)
	_time_icon = _time_box.get_child(0) as TextureRect
	_time_label = _time_box.get_child(1) as Label

	# 「可断定 N」（终极模式附加读数）：默认隐藏，开了 AddOnEarlyMineCount 才显示。
	# 单独一个次级读数（18px、次级字色），不再 `+=` 到雷数字符串上 ——
	# 那样雷数读数会随终极模式从「10」涨成「10　可断定 12」，整行宽度跳变。
	_deducible_label = Label.new()
	_deducible_label.add_theme_font_size_override("font_size", 18)
	_deducible_label.visible = false
	_deducible_label.tooltip_text = "当前盘面下仍能被纯逻辑推出的安全格数"
	_box.add_child(_deducible_label)

	# ---------- 右上单排图标簇（对齐 CozySudoku 顶栏右侧一排图标）----------
	# CozySudoku 的顶栏右上角是**一排**图标（信息/音乐/猫/调色板/手柄/显示/语言/设置）。
	# 本 HUD 现把「配置 / 全局」类图标同样收成一排，从右缘往左排：
	#   设置(0) · 换肤(1) · 毛笔(2，在 ui/drawing_toolbar.gd，通过同一组 TOOLBAR_* 常量对齐)。
	# 原先「提示 + 换肤」一行、「毛笔」另起一行，一共两行 —— 与 CozySudoku 单排不一致。
	_settings_btn = _add_icon_button(Icons.gear(), "设置（完整设置页在弹窗内「完整设置…」）",
		func(): _open_settings())
	_settings_btn.name = "SettingsBtn"
	_settings_btn.set_meta("settings_btn", true)
	add_child(_settings_btn)
	_place_toolbar_button(_settings_btn, 0, 0)

	_skin_btn = preload("res://ui/theme_picker_button.gd").new()
	_skin_btn.name = "SkinBtn"
	_skin_btn.set_meta("skin_btn", true)
	add_child(_skin_btn)
	_place_toolbar_button(_skin_btn, 0, 1)

	# ---------- 右列：对局工具列（对齐 CozySudoku 棋盘右侧工具列：图标 + 文字）----------
	# CozySudoku 把「印章 / 笔记 / 擦除 / 检查 / 撤销」竖排在**棋盘右侧**，图标 + 文字。
	# 本项目的对局工具 = 提示 / 撤销 / 暂停，同样竖排于此；「设置」是配置项，已移到右上单排图标簇。
	_right_col = _make_side_column(false)
	_hint_btn = _add_col_icon_button(_right_col, Icons.hint(), "提示",
		"提示（H）：一步直推（100% 必然结论）· 可连续点；点击可切换三档帮助深度",
		func(): _show_hint_menu())
	_hint_btn.name = "HintBtn"
	_hint_btn.set_meta("hint_btn", true)
	# 三档求助：区域 → 一步 → 整链。H 快捷键保持给一步，鼠标点按钮才展开选择。
	_hint_menu = PopupMenu.new()
	_hint_menu.add_item("圈出可疑区域（保留 2★）", GameSession.HINT_TIER_REGION)
	_hint_menu.add_item("给一步（保留 1★）", GameSession.HINT_TIER_STEP)
	_hint_menu.add_item("给整条链（0★）", GameSession.HINT_TIER_CHAIN)
	_hint_menu.id_pressed.connect(func(id: int): GameSession.request_hint(id))
	add_child(_hint_menu)
	_add_col_icon_button(_right_col, Icons.undo(), "撤销",
		"撤销上一步翻开/插旗（Ctrl+Z），可一路退到开局",
		func(): GameSession.undo_move())
	# 【2026-09-30】暂停仍为 pause/play 双态图标（刷新在 _process 的状态缓存里）。
	_pause_btn = _add_col_icon_button(_right_col, Icons.pause(), "暂停",
		"暂停 / 继续（Esc）", func(): _toggle_pause())
	_pause_btn.name = "PauseBtn"
	# 【2026-10-09】连接透镜：**等轴菱面盘专属**的对局工具（见 _sync_lens_button）。
	# 放在 _apply_theme() 之前 —— 新按钮要吃到 _apply_theme 里的图标着色与样式。
	_sync_lens_button()
	_sync_fold_button()
	# 2026-09-28 删除「重开」与「主菜单」两个按钮（用户决策）：进行中不再提供重开
	#（终局重开在结算层 game_over）；主菜单场景已删，「关卡列表」是唯一的离开出口。

	GameSession.session_started.connect(_on_session_started)
	GameSession.session_restored.connect(_on_session_started)
	_apply_theme()


## 造一个「图标 + 数字」读数组。字号即 Label 的 font_size；图标 22px（40 按钮 − 2×9 内边距
## 的同款内容区口径，与图标按钮的视觉重量一致）。
func _make_readout(tex: Texture2D, font_size: int) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ic := TextureRect.new()
	ic.texture = tex
	ic.custom_minimum_size = Vector2(22, 22)
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(ic)
	var lb := Label.new()
	lb.add_theme_font_size_override("font_size", font_size)
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(lb)
	return box


## 把一枚图标按钮摆进右上工具簇：row 0 = 顶栏行（与顶栏内容同一条垂直中线），
## row 1 = 顶栏正下方；col = 从右缘往左的第几列（0 = 最贴右缘）。
## 两个场景共用这一组常量（见 TOOLBAR_EDGE / TOOLBAR_GAP 的注释）。
func _place_toolbar_button(b: Button, row: int, col: int = 0) -> void:
	b.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	b.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	b.grow_vertical = Control.GROW_DIRECTION_END
	var top := 12.0 + float(row) * (ICON_BTN_SIZE + TOOLBAR_GAP)
	var right := TOOLBAR_EDGE + float(col) * (ICON_BTN_SIZE + TOOLBAR_GAP)
	b.offset_left = -(right + ICON_BTN_SIZE)
	b.offset_right = -right
	b.offset_top = top
	b.offset_bottom = top + ICON_BTN_SIZE


## 图标按钮：40×40 方形、样式走 UiTheme.style_icon_button（对称 9px 内边距）、
## 图标色随主题刷新（不覆盖 icon_*_color 的白图标在浅色主题下直接看不见）。
## **不自动入树** —— 提示锚右上角（HUD 直挂）、教程要排进 _box，挂到哪由调用方决定。
func _add_icon_button(tex: Texture2D, tip: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = ""
	b.icon = tex
	b.expand_icon = true
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(ICON_BTN_SIZE, ICON_BTN_SIZE)
	b.focus_mode = Control.FOCUS_ALL
	b.pressed.connect(on_pressed)
	_icon_buttons.append(b)
	return b


## 侧列容器（2026-09-28）：竖排、半透明（悬停显形）、**不吃空白点击**。
## 定位用 anchors + grow 方向（让容器按内容最小尺寸从锚点生长，不写死尺寸）：
##   左列 = 左边缘垂直居中向右生长；右列 = 右边缘垂直居中向左生长。
func _make_side_column(is_left: bool) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.anchor_top = 0.5
	col.anchor_bottom = 0.5
	if is_left:
		col.anchor_left = 0.0
		col.anchor_right = 0.0
		col.grow_horizontal = Control.GROW_DIRECTION_END
		col.offset_left = 12.0
	else:
		col.anchor_left = 1.0
		col.anchor_right = 1.0
		col.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		col.offset_right = -12.0
	col.grow_vertical = Control.GROW_DIRECTION_BOTH
	# 半透明：竖列压在棋盘两侧，全不透明会挡视线。悬停 → 整列 1.0 显形；
	# 容器自身 IGNORE 收不到鼠标事件 ⇒ 显形挂在**按钮级** enter/exit（见 _add_col_button）。
	col.modulate = Color(1, 1, 1, SIDE_COL_IDLE_ALPHA)
	add_child(col)
	return col


## 侧列按钮：竖排、悬停让整列显形、键盘可聚焦（无障碍基线不降）。
func _add_col_button(col: VBoxContainer, text: String, tip: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(84, 38)
	b.pressed.connect(on_pressed)
	b.mouse_entered.connect(func(): col.modulate.a = 1.0)
	b.mouse_exited.connect(func(): col.modulate.a = SIDE_COL_IDLE_ALPHA)
	# 键盘焦点同样让整列显形（无障碍）：键盘用户没有"鼠标悬停"这个信号，
	# Tab 落到半透明按钮上时必须也能看清。
	b.focus_entered.connect(func(): col.modulate.a = 1.0)
	b.focus_exited.connect(func(): col.modulate.a = SIDE_COL_IDLE_ALPHA)
	col.add_child(b)
	_side_buttons.append(b)
	return b


## 工具列按钮（**图标 + 文字**）：对齐 CozySudoku 棋盘右侧工具列的形态
## （印章/笔记/擦除/检查/撤销 都是「图标在上、文字在下」的方块按钮）。
## 与 _add_col_button 同类（半透明、悬停/焦点显形、键盘可聚焦），差别只在带图标。
## 图标为白模 SVG，靠 _apply_theme 里的 _style_icon_colors 随主题乘色。
func _add_col_icon_button(col: VBoxContainer, tex: Texture2D, text: String, tip: String,
		on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	if tex != null:
		b.icon = tex
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(84, 40)
	b.pressed.connect(on_pressed)
	b.mouse_entered.connect(func(): col.modulate.a = 1.0)
	b.mouse_exited.connect(func(): col.modulate.a = SIDE_COL_IDLE_ALPHA)
	b.focus_entered.connect(func(): col.modulate.a = 1.0)
	b.focus_exited.connect(func(): col.modulate.a = SIDE_COL_IDLE_ALPHA)
	col.add_child(b)
	_side_buttons.append(b)
	return b


func _add_button(text: String, tip: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	# 键盘可聚焦（2026-09-25 审计补）：对局 HUD 此前一律 FOCUS_NONE —— 进了对局之后
	# 除棋盘外的所有按钮（教程 / 暂停 / 提示 / 撤销 / 设置 / 重开 / 关卡列表 / 主菜单）
	# **只能用鼠标**，键盘用户连暂停都按不了。焦点样式由 UiTheme.style_button 提供
	# （见 _apply_theme；那里此前还有个容器类型 bug，一并修了）。
	b.focus_mode = Control.FOCUS_ALL
	b.pressed.connect(on_pressed)
	_box.add_child(b)
	return b


## 打开「当前变体」的教程（对局内入口，2026-09-23）。
##
## 与「暂停」按钮的区别：这里是**静默暂停**——玩家读规则时计时不该继续空转，
## 但不弹暂停面板（要的是教程，不是暂停菜单）。
##
## 依赖倒置：覆盖层保持通用（不认识对局状态），暂停/恢复由 HUD 负责；恢复挂在
## 覆盖层的 tree_exited 上——用户按 ESC 还是点「关闭」都走同一条路，不会漏恢复。
## 连点按钮时 show_for 复用已有覆盖层：那时 was_playing 已经是 false（状态已 PAUSED），
## 不会重复暂停；先连接的那次回调在释放时按条件只恢复一次。
func _open_tutorial() -> void:
	var was_playing: bool = GameSession.state == GameSession.State.PLAYING
	if was_playing:
		GameSession.set_paused(true)
	var ov: Control = TutorialOverlayScript.show_for(_overlay_host(),
			GameSession.current_variant_id())
	if ov == null:
		if was_playing:
			GameSession.set_paused(false)  # 覆盖层没建起来，别把对局留在暂停里
		return
	ov.tree_exited.connect(func():
		if was_playing and GameSession.state == GameSession.State.PAUSED:
			GameSession.set_paused(false))


## 教程覆盖层的宿主：必须是**能铺满全屏**的 Control。
## 优先 `current_scene`（board_view 场景根）——HUD 本体只有 64px 高，相对它铺全屏预设
## 只会盖住顶栏。极端情况（current_scene 为空，如某些测试宿主）退回 HUD 的父节点，
## 保证入口在任何宿主下都能弹出，而不是静默什么也不发生。
func _overlay_host() -> Node:
	var scene := get_tree().current_scene
	if scene != null:
		return scene
	var parent := get_parent()
	return parent if parent != null else self


## 暂停交给 board_view（它持有暂停面板），避免在 HUD 里重复维护一份 UI。
func _toggle_pause() -> void:
	var bv := get_tree().current_scene
	if bv != null and bv.has_method("toggle_pause"):
		bv.call("toggle_pause")


# ============ 连接透镜（不可能几何盘专属，2026-10-09） ============

## 本对局的 BoardView（透镜的持有者）。**先从父链找**（HUD 由 board_view 挂进来，见
## board_view._ready 的 add_child(hud)），找不到再退回 current_scene。
## 为什么不照抄 _toggle_pause 只认 current_scene：单测里 HUD 常被单独实例化，那时
## current_scene 不是对局场景 —— 本函数保证「找不到就是不装按钮」，绝不抛错。
func _lens_target() -> Node:
	var n: Node = get_parent()
	while n != null:
		if n.has_method("supports_lens"):
			return n
		n = n.get_parent()
	var tree := get_tree()
	var scene: Node = tree.current_scene if tree != null else null
	if scene != null and scene.has_method("supports_lens"):
		return scene
	return null


## 按当前棋盘决定装 / 拆透镜按钮（幂等：重复调用不会装出第二枚）。
## 判据 = `BoardView.supports_lens()`（**唯一事实源**：本盘真的是等轴菱面且几何齐备）——
## HUD 不复制任何几何规则，免得两处判据漂移成「按钮在、点开没东西」或反之。
func _sync_lens_button() -> void:
	var target := _lens_target()
	var want := target != null and bool(target.call("supports_lens"))
	if want == (_lens_btn != null):
		return
	if want:
		_lens_btn = _add_col_icon_button(_right_col, Icons.lens(), "透镜",
			"连接透镜：实心钉 = 真的相邻；空心叉 = 只是看着碰上（不算相邻）。"
			+ "点一下让全盘常驻显示，再点收起",
			func(): _toggle_lens())
		_lens_btn.name = "LensBtn"
		_lens_btn.set_meta("lens_btn", true)   # 测试 / 调试据此定位（有文字也能找，但 meta 不受文案改动影响）
	else:
		var gone := _lens_btn
		_lens_btn = null
		_side_buttons.erase(gone)   # 先摘出处，再释放：_apply_theme 会遍历这张表
		_right_col.remove_child(gone)
		gone.queue_free()


## 透镜开关转发给 BoardView（几何与判据都在它手里，HUD 只负责这一次点击）。
func _toggle_lens() -> void:
	var target := _lens_target()
	if target != null and target.has_method("toggle_lens"):
		target.call("toggle_lens")


# ============ 静态折叠（折叠盘专属，2026-10-09） ============

## 本对局的 BoardView（折叠视图的持有者）。与 _lens_target 同一套路：先父链、再 current_scene，
## 找不到就是不装按钮，绝不抛错（单测里 HUD 常被单独实例化）。
func _fold_target() -> Node:
	var n: Node = get_parent()
	while n != null:
		if n.has_method("supports_fold"):
			return n
		n = n.get_parent()
	var tree := get_tree()
	var scene: Node = tree.current_scene if tree != null else null
	if scene != null and scene.has_method("supports_fold"):
		return scene
	return null


## 按当前棋盘决定装 / 拆「折起来」按钮（幂等）。判据 = BoardView.supports_fold()（唯一事实源）。
func _sync_fold_button() -> void:
	var target := _fold_target()
	var want := target != null and bool(target.call("supports_fold"))
	if want == (_fold_btn != null):
		return
	if want:
		_fold_btn = _add_col_icon_button(_right_col, Icons.fold(), "折起来",
			"静态折叠：这条折痕把远侧翻过来压在近侧上，两层贴住 = 互为邻居。"
			+ "点一下在「折起来 / 摊平看」之间切换（摊平会画出每一对的镜像连线）",
			func(): _toggle_fold_view())
		_fold_btn.name = "FoldBtn"
		_fold_btn.set_meta("fold_btn", true)   # 测试 / 调试据此定位（meta 不受文案改动影响）
	else:
		var gone := _fold_btn
		_fold_btn = null
		_side_buttons.erase(gone)   # 先摘出处，再释放：_apply_theme 会遍历这张表
		_right_col.remove_child(gone)
		gone.queue_free()


## 折叠视图开关转发给 BoardView（几何与判据都在它手里，HUD 只负责这一次点击）。
func _toggle_fold_view() -> void:
	var target := _fold_target()
	if target != null and target.has_method("toggle_fold_view"):
		target.call("toggle_fold_view")


## 打开对局内设置弹窗（缓存单实例，复用不重复创建）
func _open_settings() -> void:
	if _settings_popup == null or not is_instance_valid(_settings_popup):
		_settings_popup = load("res://ui/settings_popup.tscn").instantiate()
		# 【09-28 审计修复 R9】原为 `get_tree().current_scene.add_child(...)` —— 无判空、无兜底；
		# 非标准宿主（单测里实例化 HUD、或场景尚未挂接到 current_scene）会 null 报错，
		# 表现为"点设置没反应"。复用同文件既有的 `_overlay_host()`（current_scene → 父节点 → self）。
		_overlay_host().add_child(_settings_popup)
		_settings_popup.hide()  # Window 默认 visible=true，不显式隐藏会立刻弹出
	# 对局内不提供「完整设置…」入口（2026-09-28）：整页设置的返回是选关页，
	# 从这里进去返回时会**离开对局**（原行为也是对局内只有子集弹窗）。
	_settings_popup.set_full_settings_entry(false)
	_settings_popup.popup_centered()


# ============ 换肤下拉面板（2026-09-29） ============
#
# 点调色板图标 → 按钮正下方弹出主题列表（当前主题 accent 高亮 + ✓ 前缀）；
# 点选任意主题：面板收起 → `SettingsManager.set_theme_mode(id)`（持久化）→
# ThemeManager 分层过渡（几何→材质→配色三段，~0.48s）承担全部换肤动画，
func _process(_delta: float) -> void:
	if _mines_label == null:
		return
	# 【2026-09-30 图标化】暂停/继续图标随 GameSession 状态切换（含 Esc 键路径）。
	var paused: bool = GameSession.state == GameSession.State.PAUSED
	if paused != _pause_icon_shown_paused and _pause_btn != null:
		_pause_icon_shown_paused = paused
		_pause_btn.icon = Icons.play() if paused else Icons.pause()
		_pause_btn.text = "继续" if paused else "暂停"   # 图标 + 文字双态（对齐工具列形态）
		_pause_btn.tooltip_text = "继续（Esc）" if paused else "暂停 / 继续（Esc）"
	_refresh_hint_button()
	var board: Board = GameSession.board
	var total: int = int(GameSession.elapsed)
	# 计时显示每秒才变一次；雷数只随旗子变。都没变就完全不做事（原实现每帧遍历全盘）
	if total == _last_shown_sec and _flag_cache >= 0 and board != null:
		return
	_last_shown_sec = total
	if board == null:
		_mines_label.text = "0"
		_time_label.text = "00:00"
		return
	# 终极模式附加开关（doc10 §2.3 AddOnMines / AddOnHideCount）：
	# 勾选「隐藏剩余雷数」时只显示符号，不泄露计数。
	var ult: bool = SettingsManager.no_guess_mode == GameSession.NO_GUESS_ULTIMATE
	var left_mines: int = board.total_mines - _flag_count(board)
	if ult and SettingsManager.ult_hide_mines:
		_mines_label.text = "?"
	elif left_mines >= 0:
		_mines_label.text = str(left_mines)
	else:
		# 旗插多了：**负数 + danger 字色**说清楚，不再拖一句「（旗标多了）」——
		# 那句把读数拉宽一整段，且红色本身已经足够醒目。细节进 tooltip。
		_mines_label.text = str(left_mines)
		_mines_box.tooltip_text = "旗标比雷多了 %d 个 —— 拔掉多余的旗，数字就回正" % -left_mines
	# 字色：负数 = danger 配对字色（无障碍口径见 ThemeManager.danger_text），正常 = 正文色。
	_mines_label.add_theme_color_override("font_color",
		ThemeManager.danger_text() if left_mines < 0 else ThemeManager.text())
	# AddOnEarlyMineCount 的反面：默认隐藏「剩余可断定格数」；开启时才显示。
	# 只在显示时才算（推导含 CP-SAT，避免默认路径白付性能）。
	_deducible_label.visible = ult and not SettingsManager.ult_hide_deducible
	if _deducible_label.visible:
		# 0.5s 节流：显示层允许的滞后，换取推导不再每帧全盘执行
		var now_ms := Time.get_ticks_msec()
		if now_ms - _deducible_at_ms > 500:
			_deducible_cache = GameSession.deducible_safe_count()
			_deducible_at_ms = now_ms
		_deducible_label.text = "可断定 %d" % _deducible_cache
	# 【09-28 审计修复 A8】原为 `total / 60`（int/int ⇒ 截断）——已开启 `integer_division` 警告，
	# 这里改成显式浮点除法 + floor，语义与旧行为**逐值相同**（total 为非负秒数），但不再掩盖意图。
	_time_label.text = "%02d:%02d" % [floori(total / 60.0), total % 60]


## 提示按钮：反映提示模式（禁用态置灰）。
## 2026-09-28（用户决策）：充能机制退役（每次只给 ≤2 格、且不消耗）——原先的百分比显示
## 分支随之删除；文案回到静态「提示」，tooltip 说明「每次 1~2 格、可连续点」的新口径。
## 2026-09-29：改成**图标按钮**后「禁用」的可见性只能靠 `icon_disabled_color`（置灰）
## + tooltip，不再有文字可换 —— 所以这里只维护 tooltip 与 disabled 两个量。
func _refresh_hint_button() -> void:
	if _hint_btn == null:
		return
	var tip := "提示（H）：一步直推（100% 必然结论）· 点击可在区域 / 一步 / 整条链之间选择"
	if SettingsManager.hint_mode == GameSession.HINT_DISABLED:
		tip = "当前设置已禁用提示，可在设置页开启"
	elif SettingsManager.no_guess_mode == GameSession.NO_GUESS_ULTIMATE:
		tip = "提示（H）：一步直推；若推不出安全格会揭开全部星号继续对局"
	if _hint_btn.tooltip_text != tip:
		_hint_btn.tooltip_text = tip
	var disabled := SettingsManager.hint_mode == GameSession.HINT_DISABLED
	_hint_btn.disabled = disabled
	if _hint_menu != null:
		for i in _hint_menu.item_count:
			_hint_menu.set_item_disabled(i, disabled)


## 旗数统计（红线 7：禁独立计数器 → 这里依然是从棋盘数出来的，
## 但用 cell_state_changed 做脏标记缓存，不必每帧全量遍历）。
func _flag_count(board: Board) -> int:
	if _flag_cache < 0:
		var count := 0
		if board.grid != null:
			# 用 all_positions()（v2.9.3）：AdjacencyGrid.size() 是包围盒，
			# 按 size 双重循环会把洞格 get_cell()==null 当 Cell 用而报错。
			for pos in board.grid.all_positions():
				var cell: Cell = board.grid.get_cell(pos)
				if cell != null and cell.state == Cell.State.FLAGGED:
					count += 1
		_flag_cache = count
	return _flag_cache


func _on_session_started() -> void:
	_flag_cache = -1
	_last_shown_sec = -1
	_sync_lens_button()   # 换关可能换掉「本盘支不支持透镜」这件事（幂等，多数时候无事发生）
	_sync_fold_button()   # 折叠按钮同理（幂等）
	if GameSession.board != null and not GameSession.board.cell_state_changed.is_connected(_on_cell_changed):
		GameSession.board.cell_state_changed.connect(_on_cell_changed)


func _on_cell_changed(_pos: Vector2i) -> void:
	_flag_cache = -1


func _apply_theme() -> void:
	if _mines_label != null:
		_mines_label.add_theme_color_override("font_color", ThemeManager.text())
		_time_label.add_theme_color_override("font_color", ThemeManager.text())
		_deducible_label.add_theme_color_override("font_color", ThemeManager.text_secondary())
		# 读数图标（TextureRect 没有主题着色项）直接用 modulate —— 白色 SVG × 主题字色。
		for ic: TextureRect in [_mines_icon, _time_icon]:
			if ic != null:
				ic.modulate = ThemeManager.text()
		# 直接遍历 `_box` 的子节点，不再按容器类型猜（2026-09-25 修 bug）：
		# 这里原写 `if n is HBoxContainer`，而 _box 在窄窗换行改造时已换成
		# **HFlowContainer** ⇒ 条件永远不成立 ⇒ 所有 HUD 按钮的样式（含 focus 态）
		# 从未被应用。按类型找容器是脆的，按钮都在 _box 里，直接扫它。
		# ⚠️ 图标按钮（教程）也挂在 _box 里，但必须走下面那段对称内边距的图标样式
		#    —— 文字按钮的 16/8 会把 40×40 的内容区压成 8×8（UiTheme.ICON_PAD 的坑）。
		for c in _box.get_children():
			if c is Button and not _icon_buttons.has(c):
				UiTheme.style_button(c)
		# 图标按钮（2026-09-29）：与文字按钮**不同**的内边距（对称 9px），
		# 且 icon_*_color 必须显式覆盖 —— 白图标在浅色主题下直接看不见。
		for b in _icon_buttons:
			if is_instance_valid(b):
				UiTheme.style_icon_button(b)
				_style_icon_colors(b)
		# 侧列按钮（2026-09-28）：容器是 IGNORE 的半透明层，样式逐个应用——
		# 维护显式数组比按容器类型猜稳（同上一段的教训：类型判定会随改造过期）。
		for b in _side_buttons:
			if is_instance_valid(b):
				UiTheme.style_button(b)
				_style_icon_colors(b)   # 工具列按钮带图标（提示/撤销/暂停），图标随主题乘色
	queue_redraw()


## 图标着色（与 level_select._style_icon_button 同一套口径，五态一起给）。
## 图标本体是白色 SVG，靠 icon_*_color 乘色随主题走。
func _style_icon_colors(b: Button) -> void:
	b.add_theme_color_override("icon_normal_color", ThemeManager.text())
	b.add_theme_color_override("icon_hover_color", ThemeManager.text())
	b.add_theme_color_override("icon_pressed_color", ThemeManager.accent_text())
	b.add_theme_color_override("icon_focus_color", ThemeManager.text())
	# 禁用态（提示被关掉时）走次级字色：置灰但仍然看得见，而不是消失。
	b.add_theme_color_override("icon_disabled_color", ThemeManager.text_secondary())


## 打开三档提示菜单（鼠标路径）。H 键仍走 GameSession.request_hint() 的默认「给一步」。
func _show_hint_menu() -> void:
	if _hint_menu == null or _hint_btn == null:
		return
	if SettingsManager.hint_mode == GameSession.HINT_DISABLED:
		return
	var at := Vector2i(_hint_btn.global_position)
	at.y += int(_hint_btn.size.y)
	_hint_menu.popup(Rect2i(at, Vector2i(240, 0)))


func _on_theme_changed() -> void:
	_apply_theme()
	if _pause_btn != null:
		_style_icon_colors(_pause_btn)   # 【2026-09-30 图标化】暂停图标色随主题走
