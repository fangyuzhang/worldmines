# main_menu.gd —— 主菜单 + 未完成对局自动恢复【plan1.1 §10.7.7-①】
# 文案唯一来源 §8.5：标题「世界扫雷」，按钮 开始游戏/设置/退出。
# v3.2：检测到未完成对局不再弹窗询问，直接自动恢复；无法恢复时隔离备份 + toast。
extends Control

# 教程覆盖层用 preload 而非 class_name 引用（headless 下新全局类不在 .godot 缓存里，见坑表 #26）
const TutorialOverlayScript := preload("res://ui/tutorial_overlay.gd")

## 自动恢复进程级门控：每次启动只在**首次进入主菜单**时尝试一次。
## 必须用 static（场景节点会随切页重建，实例字段保不住）——否则「暂停→回主菜单」
## 会立刻又被自动恢复弹回对局，用户永远到不了主菜单。
static var _auto_restore_done := false


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

## 自动恢复（v3.2）：MAIN 里存在未终局的进行中对局就直接续上，不再弹窗询问。
## 触发源不再只看 TEMP 崩溃残留——主动退出 / 回主菜单（save_now 落盘）后下次启动同样恢复。
## 恢复失败（坏档 / 异常残留档）→ 隔离 .bak + toast，留在主菜单（§10.7.4）。
## 原弹窗流程的历史问题：测试或异常路径写出的残档（如 level_path 为空）走到「恢复」
## 一律报「存档已损坏」，玩家被无效弹窗打断；现在能恢复就静默恢复，不能就安静隔离。
func _check_crash_restore() -> void:
    if _auto_restore_done:
        return
    _auto_restore_done = true
    var d := SaveCoordinator.load_save()
    if d.is_empty():
        # TEMP 残留但读不出 → 真坏档，隔离（保留原崩溃检测口径）
        if SaveCoordinator.has_crash_leftover():
            SaveCoordinator.quarantine()
            _toast("存档无法恢复，已隔离备份")
        return
    var meta_v: Variant = d.get("metadata", {})
    var meta: Dictionary = meta_v if meta_v is Dictionary else {}
    if bool(meta.get("ended", false)):
        return  # 终局盘不可恢复（失败局 SL 复活禁令，见 restore_from_save 同口径）
    if GameSession.restore_from_save():
        # 注：本函数在 _ready 调用链里执行，此刻根节点正忙于增删子节点，
        # 直接 change_scene_to_file 会报「Parent node is busy」（remove_child 被拒）——延后到帧末执行。
        get_tree().change_scene_to_file.call_deferred("res://ui/board_view.tscn")
    else:
        SaveCoordinator.quarantine()
        _toast("存档无法恢复，已隔离备份")


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
