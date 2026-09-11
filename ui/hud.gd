# hud.gd —— 顶栏（雷数 / 计时 / 重开 / 返回）【plan1.1 §10.7.7-④】
# 文案 §8.5：「雷数」+ 数字（允许为负）；「时间」+ MM:SS。
# flag_count() 实时遍历；禁独立计数器。
extends Control

var _mines_label: Label
var _time_label: Label
var _settings_popup: PopupPanel


## 打开对局内设置弹窗（缓存单实例，复用不重复创建）
func _open_settings() -> void:
    if _settings_popup == null or not is_instance_valid(_settings_popup):
        _settings_popup = load("res://ui/settings_popup.tscn").instantiate()
        get_tree().current_scene.add_child(_settings_popup)
    _settings_popup.popup_centered()


func _ready() -> void:
    add_to_group("themed")
    ThemeManager.theme_changed.connect(_on_theme_changed)
    set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    offset_bottom = 64  # 明确顶栏高度，避免 28px 字体溢出顶部被裁剪
    custom_minimum_size = Vector2(0, 64)

    var box := HBoxContainer.new()
    box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    box.offset_left = 24
    box.offset_right = -24
    box.add_theme_constant_override("separation", 32)
    add_child(box)

    _mines_label = Label.new()
    _mines_label.add_theme_font_size_override("font_size", 28)
    box.add_child(_mines_label)

    _time_label = Label.new()
    _time_label.add_theme_font_size_override("font_size", 28)
    _time_label.size_flags_horizontal = Control.SIZE_EXPAND
    box.add_child(_time_label)

    var hint := Button.new()
    hint.text = "提示"
    hint.focus_mode = Control.FOCUS_NONE
    hint.pressed.connect(func(): GameSession.request_hint())
    box.add_child(hint)

    var settings := Button.new()
    settings.text = "设置"
    settings.focus_mode = Control.FOCUS_NONE
    settings.pressed.connect(_open_settings)
    box.add_child(settings)

    var restart := Button.new()
    restart.text = "重开"
    restart.focus_mode = Control.FOCUS_NONE
    restart.pressed.connect(func(): GameSession.restart())
    box.add_child(restart)

    var levels := Button.new()
    levels.text = "返回"
    levels.focus_mode = Control.FOCUS_NONE
    levels.pressed.connect(func():
        SaveCoordinator.clear()  # 主动离开对局：全清（§10.7.8）
        get_tree().change_scene_to_file("res://ui/level_select.tscn"))
    box.add_child(levels)

    var back := Button.new()
    back.text = "返回菜单"
    back.focus_mode = Control.FOCUS_NONE
    back.pressed.connect(func():
        SaveCoordinator.clear()  # 主动结束对局：全清（§10.7.8）
        get_tree().change_scene_to_file("res://ui/main_menu.tscn"))
    box.add_child(back)

    _apply_theme()


func _process(_delta: float) -> void:
    if _mines_label == null:
        return
    var board: Board = GameSession.board
    if board == null:
        _mines_label.text = "雷数 0"
        _time_label.text = "时间 00:00"
        return
    # 终极模式附加开关（doc10 §2.3 AddOnMines / AddOnHideCount）：
    # 勾选「隐藏剩余雷数」时只显示符号，不泄露计数。
    var ult: bool = SettingsManager.no_guess_mode == GameSession.NO_GUESS_ULTIMATE
    if ult and SettingsManager.ult_hide_mines:
        _mines_label.text = "雷数 ?"
    else:
        _mines_label.text = "雷数 %d" % (board.total_mines - _flag_count(board))
    # AddOnEarlyMineCount 的反面：默认隐藏「剩余可断定格数」；开启时才显示。
    # 只在显示时才算（推导含 CP-SAT，避免默认路径白付性能）。
    if ult and not SettingsManager.ult_hide_deducible:
        _mines_label.text += "　可断定 %d" % GameSession.deducible_safe_count()
    var total: int = int(GameSession.elapsed)
    var m: int = total / 60
    var s: int = total % 60
    _time_label.text = "时间 %02d:%02d" % [m, s]


## 旗数实时统计：遍历（红线 7：禁独立计数器）
func _flag_count(board: Board) -> int:
    var count := 0
    if board.grid == null:
        return 0
    var size := board.grid.size()
    for r in size.y:
        for c in size.x:
            if board.grid.get_cell(Vector2i(c, r)).state == Cell.State.FLAGGED:
                count += 1
    return count


func _apply_theme() -> void:
    if _mines_label != null:
        _mines_label.add_theme_color_override("font_color", ThemeManager.text())
        _time_label.add_theme_color_override("font_color", ThemeManager.text())
        for n in get_children():
            if n is HBoxContainer:
                for c in n.get_children():
                    if c is Button:
                        _style_button(c)
    queue_redraw()


func _style_button(btn: Button) -> void:
    UiTheme.style_button(btn)


func _on_theme_changed() -> void:
    _apply_theme()
