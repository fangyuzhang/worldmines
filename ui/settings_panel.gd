# settings_panel.gd —— 设置面板（6 项开关 + 通关进度清除，实时生效 + 持久化）【plan1.1 §10.7.7-⑥】
# 文案 §8.5：标题「设置」，6 项开关 = 主题模式（跟随系统/深色/亮色）、
# 翻开涟漪动效、悬停邻域高亮、自动存档、键盘操作、音效；外加「通关进度 → 清除…」（二次确认）；按钮「返回」。
extends Control

var _theme_opt: OptionButton
var _ripple_chk: CheckButton
var _hover_chk: CheckButton
var _autosave_chk: CheckButton
var _keyboard_chk: CheckButton
var _sfx_chk: CheckButton
var _fullscreen_chk: CheckButton
var _quick_chk: CheckButton
var _drawing_save_chk: CheckButton


func _ready() -> void:
    add_to_group("themed")
    ThemeManager.theme_changed.connect(_on_theme_changed)
    _build_ui()


func _build_ui() -> void:
    var top := HBoxContainer.new()
    top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    top.offset_top = 12
    top.add_theme_constant_override("separation", 16)
    add_child(top)

    var title := Label.new()
    title.text = "设置"
    title.add_theme_font_size_override("font_size", 28)
    top.add_child(title)

    # 返回按钮：统一右上角（独立定位）
    var back := Button.new()
    back.text = "返回"
    back.focus_mode = Control.FOCUS_NONE
    back.custom_minimum_size = Vector2(96, 40)
    back.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
    back.offset_left = -120
    back.offset_top = 12
    back.offset_right = -24
    back.offset_bottom = 52
    back.pressed.connect(func(): get_tree().change_scene_to_file("res://ui/main_menu.tscn"))
    add_child(back)

    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    center.offset_top = 64
    add_child(center)

    var panel := PanelContainer.new()
    center.add_child(panel)

    var tabs := TabContainer.new()
    panel.add_child(tabs)

    var vbox := VBoxContainer.new()
    vbox.name = "通用"
    vbox.add_theme_constant_override("separation", 18)
    tabs.add_child(vbox)

    var skin_page: Control = load("res://ui/skin_browser.tscn").instantiate()
    skin_page.name = "皮肤"
    tabs.add_child(skin_page)

    # 行 1：主题模式
    var row1 := HBoxContainer.new()
    row1.add_theme_constant_override("separation", 24)
    _add_label(row1, "主题模式")
    _theme_opt = OptionButton.new()
    _theme_opt.add_item("跟随系统")
    _theme_opt.add_item("深色")
    _theme_opt.add_item("亮色")
    _theme_opt.item_selected.connect(func(idx: int):
        SettingsManager.set_theme_mode(["system", "dark", "light"][idx]))
    row1.add_child(_theme_opt)
    vbox.add_child(row1)

    # 行 2~5：四开关
    _ripple_chk = _add_check_row(vbox, "翻开涟漪动效",
        func(v: bool): SettingsManager.set_ripple_enabled(v))
    _hover_chk = _add_check_row(vbox, "悬停邻域高亮",
        func(v: bool): SettingsManager.set_hover_highlight(v))
    _autosave_chk = _add_check_row(vbox, "自动存档",
        func(v: bool): SettingsManager.set_autosave_enabled(v))
    _keyboard_chk = _add_check_row(vbox, "键盘操作",
        func(v: bool): SettingsManager.set_keyboard_enabled(v))
    _sfx_chk = _add_check_row(vbox, "音效",
        func(v: bool): SettingsManager.set_sfx_enabled(v))
    # 全屏模式：勾选 = 独占全屏（无边框）；取消 = 窗口模式（可自由调整大小）
    _fullscreen_chk = _add_check_row(vbox, "全屏模式",
        func(v: bool): SettingsManager.set_fullscreen(v))
    # 连携操作：一键展开（chord）+ 右键拖动插旗。默认开；误触多可关
    _quick_chk = _add_check_row(vbox, "连携操作（一键展开 / 拖动插旗）",
        func(v: bool): SettingsManager.set_quick_actions(v))
    # 绘画草稿是否写入存档：关闭后存档不含草稿，恢复对局也不还原
    _drawing_save_chk = _add_check_row(vbox, "绘画草稿存入存档",
        func(v: bool): SettingsManager.set_drawing_in_save(v))

    # 行 6：通关进度（清除，二次确认）
    var row6 := HBoxContainer.new()
    row6.add_theme_constant_override("separation", 24)
    _add_label(row6, "通关进度")
    var clear_btn := Button.new()
    clear_btn.text = "清除…"
    clear_btn.focus_mode = Control.FOCUS_NONE
    clear_btn.custom_minimum_size = Vector2(120, 32)
    clear_btn.pressed.connect(_on_clear_progress)
    row6.add_child(clear_btn)
    vbox.add_child(row6)

    # 控件初值 = SettingsManager 当前值
    _theme_opt.selected = ["system", "dark", "light"].find(SettingsManager.theme_mode)
    _ripple_chk.button_pressed = SettingsManager.ripple_enabled
    _hover_chk.button_pressed = SettingsManager.hover_highlight
    _autosave_chk.button_pressed = SettingsManager.autosave_enabled
    _keyboard_chk.button_pressed = SettingsManager.keyboard_enabled
    _sfx_chk.button_pressed = SettingsManager.sfx_enabled
    _fullscreen_chk.button_pressed = SettingsManager.fullscreen
    _quick_chk.button_pressed = SettingsManager.quick_actions
    _drawing_save_chk.button_pressed = SettingsManager.drawing_in_save

    _apply_theme()


## 清除全部通关进度（二次确认，避免误触）
func _on_clear_progress() -> void:
    var dlg := ConfirmationDialog.new()
    dlg.dialog_text = "清除全部通关进度（不可恢复）？"
    dlg.ok_button_text = "清除"
    dlg.cancel_button_text = "取消"
    dlg.confirmed.connect(func():
        ProgressStore.clear_all()
        _toast("通关进度已清除", false))
    # 关闭即释放（v3.1）：反复打开清除确认不再累积隐藏节点
    dlg.visibility_changed.connect(func():
        if not dlg.visible:
            dlg.queue_free())
    add_child(dlg)
    dlg.popup_centered()


## toast 统一走 UiToast（原先本页与 mod_select / skin_browser / main_menu
## 各实现了一份同构的 Label+Timer，行为与配色已经开始分叉）。
func _toast(msg: String, danger: bool = true) -> void:
    UiToast.popup(self, msg, danger)


func _add_check_row(parent: Node, label: String, setter: Callable) -> CheckButton:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 24)
    _add_label(row, label)
    var chk := CheckButton.new()
    chk.toggled.connect(setter)
    row.add_child(chk)
    parent.add_child(row)
    return chk


func _add_label(parent: Node, text: String) -> void:
    var lb := Label.new()
    lb.text = text
    lb.custom_minimum_size = Vector2(200, 32)
    lb.add_theme_font_size_override("font_size", 18)
    parent.add_child(lb)


func _apply_theme() -> void:
    for n in get_children():
        if n is HBoxContainer:
            for c in n.get_children():
                if c is Label:
                    c.add_theme_color_override("font_color", ThemeManager.text())
                elif c is Button:
                    _style_button(c)
        elif n is CenterContainer:
            for p in n.get_children():
                if p is PanelContainer:
                    var sb := StyleBoxFlat.new()
                    sb.bg_color = ThemeManager.card()
                    sb.set_corner_radius_all(10)
                    p.add_theme_stylebox_override("panel", sb)
                    for v in p.get_children():
                        if v is TabContainer:
                            for tab in v.get_children():
                                if tab is VBoxContainer:
                                    for row in tab.get_children():
                                        for c in row.get_children():
                                            if c is Label:
                                                c.add_theme_color_override("font_color", ThemeManager.text())
                                            elif c is Button:
                                                _style_button(c)
    queue_redraw()


func _style_button(btn: Button) -> void:
    UiTheme.style_button(btn)


func _on_theme_changed() -> void:
    _apply_theme()
