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
var _tut_btn: Button
var _settings_popup: PopupPanel
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
## 左右两列（2026-09-28）：左 = 关卡列表；右 = 暂停 / 撤销 / 设置。
var _left_col: VBoxContainer
var _right_col: VBoxContainer
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
	# 2026-09-29（形态改造）：顶栏 = ⦿雷数 · 📖教程 · ⏱时间 · 可断定；
	# 右上工具簇 = 💡提示（+ 另一场景的 🖌毛笔）；左列 = 关卡列表；右列 = 暂停·撤销·设置。
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
	# `_add_icon_button` 不进 _box（提示要锚右上角），教程这里手动入列并按「雷数组」的
	# 相对位置回插（不写死索引 1 的另一层含义：将来雷数前面再加元素时不会漂）。
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

	# ---------- 右上工具簇：提示 ----------
	# 锚到顶栏右上角（与顶栏同一行），与另一场景的「毛笔」上下成簇。
	# 不再挤在 _box 里：文字按钮和读数混排是这行看起来乱的根源之一。
	_hint_btn = _add_icon_button(Icons.hint(), "提示（H）：一步直推，每次 1~2 格",
		func(): GameSession.request_hint())
	_hint_btn.name = "HintBtn"
	_hint_btn.set_meta("hint_btn", true)
	add_child(_hint_btn)
	_place_toolbar_button(_hint_btn, 0)

	# ---------- 右上工具簇：换肤（常驻组件，hint 左侧一列；row1 已被毛笔占用）----------
	_skin_btn = preload("res://ui/theme_picker_button.gd").new()
	_skin_btn.name = "SkinBtn"
	_skin_btn.set_meta("skin_btn", true)
	add_child(_skin_btn)
	_place_toolbar_button(_skin_btn, 0, 1)

	# ---------- 左列：关卡列表 ----------
	_left_col = _make_side_column(true)
	_add_col_button(_left_col, "关卡列表", "保存进度并返回关卡选择", func():
		GameSession.save_now()
		get_tree().change_scene_to_file("res://ui/level_select.tscn"))

	# ---------- 右列：暂停 · 撤销 · 设置 ----------
	_right_col = _make_side_column(false)
	_add_col_button(_right_col, "暂停", "暂停 / 继续（Esc）", func(): _toggle_pause())
	_add_col_button(_right_col, "撤销", "撤销上一步翻开/插旗（Ctrl+Z），可一路退到开局",
		func(): GameSession.undo_move())
	_add_col_button(_right_col, "设置", "打开设置（完整设置页在弹窗内「完整设置…」）",
		func(): _open_settings())
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
	var tip := "提示（H）：一步直推（100% 必然结论）· 每次给出 1~2 格，可连续点"
	if SettingsManager.hint_mode == GameSession.HINT_DISABLED:
		tip = "当前设置已禁用提示，可在设置页开启"
	elif SettingsManager.no_guess_mode == GameSession.NO_GUESS_ULTIMATE:
		tip = "提示（H）：一步直推（每次 1~2 格）；若推不出安全格会揭开全部星号继续对局"
	if _hint_btn.tooltip_text != tip:
		_hint_btn.tooltip_text = tip
	_hint_btn.disabled = SettingsManager.hint_mode == GameSession.HINT_DISABLED


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


func _on_theme_changed() -> void:
	_apply_theme()
