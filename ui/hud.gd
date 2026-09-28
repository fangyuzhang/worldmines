# hud.gd —— 顶栏（雷数 / 计时 / 暂停 / 提示 / 重开 / 返回）【plan1.1 §10.7.7-④】
# 文案 §8.5：「雷数」+ 数字（允许为负）；「时间」+ MM:SS。
#
# 交互修正（原实现的三个真实问题）：
#   ① 「返回 / 返回菜单」两个按钮挨在一起且只差两个字，误点即 SaveCoordinator.clear()
#      ——现改为语义明确的「关卡列表 / 主菜单」，并对局进行中二次确认；
#   ② 「提示」按钮从不反映充能状态（开了 hint_charge 玩家也看不出来）——现显示百分比；
#   ③ 旗数每帧全盘遍历（O(格子数)/帧）——改为按 cell_state_changed 失效的缓存。
extends Control

# 教程覆盖层用 preload 而非 class_name 引用（headless 下新全局类不在 .godot 缓存里，见坑表 #26）
const TutorialOverlayScript := preload("res://ui/tutorial_overlay.gd")

var _mines_label: Label
var _time_label: Label
var _hint_btn: Button
var _settings_popup: PopupPanel

var _box: HFlowContainer
## 左右两列（2026-09-28）：左 = 关卡列表；右 = 暂停 / 撤销 / 设置。
var _left_col: VBoxContainer
var _right_col: VBoxContainer
## 侧列全部按钮（主题样式统一入口；容器本身 IGNORE 不吃事件，故样式按按钮收集）。
var _side_buttons: Array[Button] = []
## 侧列空闲透明度：竖列压在棋盘两侧，全不透明会挡视线；鼠标进入任一侧列按钮 → 整列 1.0。
const SIDE_COL_IDLE_ALPHA := 0.55
var _last_shown_sec: int = -1
var _flag_cache: int = -1
# 「可断定格数」0.5s 节流缓存：推导含 CP-SAT 全盘哈希，终极模式常开时每帧全算白付性能
var _deducible_cache: int = 0
var _deducible_at_ms: int = -100000


func _ready() -> void:
    add_to_group("themed")
    ThemeManager.theme_changed.connect(_on_theme_changed)
    # 2026-09-28（用户决策）：HUD 改「顶栏 + 左右两列」——
    #   顶栏：雷数 · 教程 · 时间 · 提示；左列：关卡列表；右列：暂停 · 撤销 · 设置。
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
    _box.offset_bottom = 64   # 明确顶栏高度，避免 28px 字体溢出顶部被裁剪
    _box.offset_left = 24
    _box.offset_right = -24
    _box.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _box.add_theme_constant_override("separation", 24)
    add_child(_box)

    _mines_label = Label.new()
    _mines_label.add_theme_font_size_override("font_size", 28)
    _box.add_child(_mines_label)

    # 教程入口（2026-09-23 用户决策）：从主菜单总入口改为**上下文相关**——这里放在
    # **左上角**（紧贴「雷数」：左端唯一按钮），点击看**当前变体**的教程。
    # `_add_button` 一律追加到 _box 末尾（右端按钮区），故按「雷数」的相对位置回插
    # （不写死索引 1：将来雷数前面再加元素时，教程按钮不会漂到别处去）。
    var _tut_btn: Button = _add_button("教程", "查看当前变体的教程", func(): _open_tutorial())
    _box.move_child(_tut_btn, _mines_label.get_index() + 1)

    _time_label = Label.new()
    _time_label.add_theme_font_size_override("font_size", 28)
    _time_label.size_flags_horizontal = Control.SIZE_EXPAND
    _box.add_child(_time_label)

    _hint_btn = _add_button("提示", "一步直推（H）", func(): GameSession.request_hint())

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
    _settings_popup.popup_centered()


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
        _mines_label.text = "剩余雷数 0"
        _time_label.text = "时间 00:00"
        return
    # 终极模式附加开关（doc10 §2.3 AddOnMines / AddOnHideCount）：
    # 勾选「隐藏剩余雷数」时只显示符号，不泄露计数。
    var ult: bool = SettingsManager.no_guess_mode == GameSession.NO_GUESS_ULTIMATE
    if ult and SettingsManager.ult_hide_mines:
        _mines_label.text = "剩余雷数 ?"
    else:
        # 文案与语义对齐（2026-09-25 审计）：显示的是**剩余**雷数（总雷数 − 已插旗），
        # 原名「雷数」会让玩家以为是总数。为负 = 旗插多了 —— 明确说出来，
        # 而不是摆一个玩家看不懂的负数（原先就只显示「雷数 -3」）。
        var left_mines: int = board.total_mines - _flag_count(board)
        if left_mines >= 0:
            _mines_label.text = "剩余雷数 %d" % left_mines
        else:
            _mines_label.text = "剩余雷数 %d（旗标多了）" % left_mines
    # AddOnEarlyMineCount 的反面：默认隐藏「剩余可断定格数」；开启时才显示。
    # 只在显示时才算（推导含 CP-SAT，避免默认路径白付性能）。
    if ult and not SettingsManager.ult_hide_deducible:
        # 0.5s 节流：显示层允许的滞后，换取推导不再每帧全盘执行
        var now_ms := Time.get_ticks_msec()
        if now_ms - _deducible_at_ms > 500:
            _deducible_cache = GameSession.deducible_safe_count()
            _deducible_at_ms = now_ms
        _mines_label.text += "　可断定 %d" % _deducible_cache
    # 【09-28 审计修复 A8】原为 `total / 60`（int/int ⇒ 截断）——已开启 `integer_division` 警告，
    # 这里改成显式浮点除法 + floor，语义与旧行为**逐值相同**（total 为非负秒数），但不再掩盖意图。
    _time_label.text = "时间 %02d:%02d" % [floori(total / 60.0), total % 60]


## 提示按钮：反映提示模式与充能进度。
## 原实现永远只写「提示」，开了 120 秒充能也毫无迹象，玩家无从判断能不能用。
func _refresh_hint_button() -> void:
    if _hint_btn == null:
        return
    var txt := "提示"
    var tip := "一步直推（100% 必然结论）"
    if SettingsManager.hint_mode == GameSession.HINT_DISABLED:
        txt = "提示（已禁用）"
        tip = "当前设置已禁用提示，可在设置页开启"
    elif SettingsManager.no_guess_mode == GameSession.NO_GUESS_ULTIMATE:
        tip = "一步直推；若推不出安全格会揭开全部星号继续对局"
    elif SettingsManager.hint_charge:
        var ratio := GameSession.hint_charge_ratio()
        if ratio >= 1.0:
            txt = "提示（已充满）"
        else:
            txt = "提示 %d%%" % int(floorf(ratio * 100.0))
            tip = "充能中（%d / 120 秒）；未充满也能用，只标记为非完美通关" % \
                    int(GameSession.hint_charge_left)
    if _hint_btn.text != txt:
        _hint_btn.text = txt
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
        # 直接遍历 `_box` 的子节点，不再按容器类型猜（2026-09-25 修 bug）：
        # 这里原写 `if n is HBoxContainer`，而 _box 在窄窗换行改造时已换成
        # **HFlowContainer** ⇒ 条件永远不成立 ⇒ 所有 HUD 按钮的样式（含 focus 态）
        # 从未被应用。按类型找容器是脆的，按钮都在 _box 里，直接扫它。
        for c in _box.get_children():
            if c is Button:
                UiTheme.style_button(c)
        # 侧列按钮（2026-09-28）：容器是 IGNORE 的半透明层，样式逐个应用——
        # 维护显式数组比按容器类型猜稳（同上一段的教训：类型判定会随改造过期）。
        for b in _side_buttons:
            if is_instance_valid(b):
                UiTheme.style_button(b)
    queue_redraw()


func _on_theme_changed() -> void:
    _apply_theme()
