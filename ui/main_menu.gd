# main_menu.gd —— 主菜单 + 崩溃恢复弹窗【plan1.1 §10.7.7-①】
# 文案唯一来源 §8.5：标题「世界扫雷」，按钮 开始游戏/设置/退出，
# 恢复弹窗「检测到未完成对局，是否恢复？」确认「恢复」取消「放弃」。
extends Control

# 教程覆盖层用 preload 而非 class_name 引用（headless 下新全局类不在 .godot 缓存里，见坑表 #26）
const TutorialOverlayScript := preload("res://ui/tutorial_overlay.gd")


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

    for cap in ["开始游戏", "教程", "规则图鉴", "设置", "模组", "退出"]:
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
        "教程":
            _open_tutorial()
        "规则图鉴":
            get_tree().change_scene_to_file("res://ui/codex.tscn")
        "设置":
            get_tree().change_scene_to_file("res://ui/settings_panel.tscn")
        "模组":
            get_tree().change_scene_to_file("res://ui/mod_select.tscn")
        "退出":
            SaveCoordinator.clear_temp()  # 清存活标志，防误报（§10.7.7-①）
            get_tree().quit()


## 打开教程覆盖层（对标 doc10 §1）。页列表由 res://levels/tutorial/ 自动枚举，按名称排序。
func _open_tutorial() -> void:
    var ov: Control = TutorialOverlayScript.new()
    add_child(ov)
    ov.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    ov.call("open")


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

## toast 统一走 UiToast（原先此处与 level_select 各实现了一份完全相同的 Label+Timer）。
func _toast(msg: String, danger: bool = true) -> void:
    UiToast.popup(self, msg, danger)


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
