# main_menu.gd —— 主菜单 + 崩溃恢复弹窗【plan1.1 §10.7.7-①】
# 文案唯一来源 §8.5：标题「世界扫雷」，按钮 开始游戏/设置/退出，
# 恢复弹窗「检测到未完成对局，是否恢复？」确认「恢复」取消「放弃」。
extends Control


func _ready() -> void:
    add_to_group("themed")
    ThemeManager.theme_changed.connect(_on_theme_changed)
    _build_ui()
    _check_crash_restore()


func _build_ui() -> void:
    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(center)
    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 16)
    center.add_child(vbox)
    _vbox = vbox

    var title := Label.new()
    title.text = "世界扫雷"
    title.add_theme_font_size_override("font_size", 48)
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.custom_minimum_size = Vector2(400, 64)
    vbox.add_child(title)

    for cap in ["开始游戏", "规则图鉴", "设置", "模组", "退出"]:
        var btn := Button.new()
        btn.text = cap
        btn.focus_mode = Control.FOCUS_NONE
        btn.custom_minimum_size = Vector2(240, 48)
        btn.pressed.connect(_on_button.bind(cap))
        vbox.add_child(btn)
    _title_label = title
    _apply_theme()


var _title_label: Label
var _vbox: VBoxContainer
var _buttons: Array = []


func _on_button(cap: String) -> void:
    match cap:
        "开始游戏":
            get_tree().change_scene_to_file("res://ui/level_select.tscn")
        "规则图鉴":
            get_tree().change_scene_to_file("res://ui/codex.tscn")
        "设置":
            get_tree().change_scene_to_file("res://ui/settings_panel.tscn")
        "模组":
            get_tree().change_scene_to_file("res://ui/mod_select.tscn")
        "退出":
            SaveCoordinator.clear_temp()  # 清存活标志，防误报（§10.7.7-①）
            get_tree().quit()


# ============ 崩溃恢复检测（验收项 3） ============

func _check_crash_restore() -> void:
    if not SaveCoordinator.has_crash_leftover():
        return
    var dialog := ConfirmationDialog.new()
    dialog.dialog_text = "检测到未完成对局，是否恢复？"
    dialog.ok_button_text = "恢复"
    dialog.cancel_button_text = "放弃"
    dialog.confirmed.connect(_on_restore_yes)
    dialog.canceled.connect(func(): SaveCoordinator.clear())
    add_child(dialog)
    dialog.popup_centered()


func _on_restore_yes() -> void:
    if GameSession.restore_from_save():
        get_tree().change_scene_to_file("res://ui/board_view.tscn")
    else:
        # 坏档：隔离 .bak + toast，留在主菜单（§10.7.4）
        SaveCoordinator.quarantine()
        _toast("存档已损坏，已隔离备份")


# ============ toast（场景内顶部 Label + Timer，2s 自动消失；文案 §8.5） ============

func _toast(msg: String) -> void:
    var lb := Label.new()
    lb.text = msg
    lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    lb.add_theme_font_size_override("font_size", 18)
    lb.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    lb.position = Vector2(0, 8)
    lb.custom_minimum_size = Vector2(0, 32)
    add_child(lb)
    var timer := Timer.new()
    timer.wait_time = 2.0
    timer.one_shot = true
    timer.timeout.connect(lb.queue_free)
    timer.timeout.connect(timer.queue_free)
    add_child(timer)
    timer.start()


# ============ 主题（所有色值经 ThemeManager） ============

func _apply_theme() -> void:
    if _title_label != null:
        _title_label.add_theme_color_override("font_color", ThemeManager.text())
        if _vbox != null:
            for c in _vbox.get_children():
                if c is Button:
                    _style_button(c)
    queue_redraw()


func _style_button(btn: Button) -> void:
    UiTheme.style_button(btn)


func _on_theme_changed() -> void:
    _apply_theme()
