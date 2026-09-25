# settings_popup.gd —— 对局内设置弹窗（不离开对局，实时生效）
# 与 settings_panel.gd 同源逻辑；此处作为 PopupPanel 悬浮在棋盘上。
# 改动经 SettingsManager setter 即时广播：音效/涟漪/悬停/主题/键盘等对局内立即生效。
# 注意：PopupPanel 是 Window（非 Control），主题样式只能下放到内部 Control（用 PanelContainer 承载）。
#
# 信息结构（v3.4）：弹窗空间小，不用 Tab，改为**分组标题**把同类项聚拢（外观 / 操作 / 对局与提示 / 其他）。
# 分组只是把现有项重新编排，不删项——对局内可调的项不得比分组前更少。
extends PopupPanel

var _theme_opt: OptionButton
var _ripple_chk: CheckButton
var _hover_chk: CheckButton
var _autosave_chk: CheckButton
var _keyboard_chk: CheckButton
var _sfx_chk: CheckButton
var _panel: PanelContainer

const THEME_MODES := ["system", "dark", "light"]


func _ready() -> void:
    add_to_group("themed")
    ThemeManager.theme_changed.connect(_on_theme_changed)
    exclusive = true  # 对局内设置：避免点击穿透到棋盘，也让 board_view 能识别「有弹窗」
    _build_ui()


func _build_ui() -> void:
    _panel = PanelContainer.new()
    add_child(_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 22)
    margin.add_theme_constant_override("margin_right", 22)
    margin.add_theme_constant_override("margin_top", 18)
    margin.add_theme_constant_override("margin_bottom", 18)
    _panel.add_child(margin)

    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 12)
    vbox.custom_minimum_size = Vector2(360, 0)
    margin.add_child(vbox)

    # 名字不叫 title：会遮蔽基类 Window.title（真机报 SHADOWED_VARIABLE_BASE_CLASS）
    var title_lb := Label.new()
    title_lb.text = "设置"
    title_lb.add_theme_font_size_override("font_size", 24)
    title_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    vbox.add_child(title_lb)

    # ---------- 外观 ----------
    _add_group(vbox, "外观")
    var row1 := HBoxContainer.new()
    row1.add_theme_constant_override("separation", 20)
    _add_label(row1, "主题模式")
    _theme_opt = OptionButton.new()
    _theme_opt.add_item("跟随系统")
    _theme_opt.add_item("深色")
    _theme_opt.add_item("亮色")
    _theme_opt.item_selected.connect(func(idx: int):
        SettingsManager.set_theme_mode(THEME_MODES[idx]))
    row1.add_child(_theme_opt)
    vbox.add_child(row1)

    # 翻开动效总闸（波浪 + 后续单格 pop）：唯一开关，标签即语义（test_reveal_effects 锚定此文案）
    _ripple_chk = _add_check_row(vbox, "翻开动效（波浪 / 单格）", func(v: bool): SettingsManager.set_ripple_enabled(v), SettingsManager.ripple_enabled)
    _hover_chk = _add_check_row(vbox, "悬停邻域高亮", func(v: bool): SettingsManager.set_hover_highlight(v), SettingsManager.hover_highlight)

    # 绘画层透明度（0.5~1.0）：拖动中只应用（apply 不落盘）；松手（drag_ended）才写盘。
    var op_row := HBoxContainer.new()
    op_row.add_theme_constant_override("separation", 20)
    _add_label(op_row, "绘画层透明度")
    var op_slider := HSlider.new()
    op_slider.min_value = 0.5
    op_slider.max_value = 1.0
    op_slider.step = 0.05
    op_slider.value = SettingsManager.drawing_opacity
    op_slider.custom_minimum_size = Vector2(160, 24)
    op_slider.value_changed.connect(func(v: float): SettingsManager.apply_drawing_opacity(v))
    op_slider.drag_ended.connect(func(_changed: bool): SettingsManager.save())
    op_row.add_child(op_slider)
    vbox.add_child(op_row)

    # ---------- 操作 ----------
    _add_group(vbox, "操作")
    _keyboard_chk = _add_check_row(vbox, "键盘操作", func(v: bool): SettingsManager.set_keyboard_enabled(v), SettingsManager.keyboard_enabled)
    # 连携操作：一键展开（chord）+ 右键拖动插旗，与设置页同项（对局内可即时关闭）
    _add_check_row(vbox, "连携操作（一键展开 / 拖动插旗）",
        func(v: bool): SettingsManager.set_quick_actions(v), SettingsManager.quick_actions)

    # ---------- 对局与提示 ----------
    _add_group(vbox, "对局与提示")
    # 无猜模式（对标 doc10 §2）：关闭 / 专家（禁止猜测）/ 终极
    # 注：本作「禁止猜测」= 拒绝翻开推不出来的格（不移动雷位，兼容 R01 红线）
    var ng_row := HBoxContainer.new()
    ng_row.add_theme_constant_override("separation", 20)
    _add_label(ng_row, "无猜模式")
    var ng_opt := OptionButton.new()
    ng_opt.add_item("关闭")
    ng_opt.add_item("专家（禁止猜测）")
    ng_opt.add_item("终极（新线索打星号）")
    ng_opt.selected = clampi(SettingsManager.no_guess_mode, 0, 2)
    ng_opt.item_selected.connect(func(idx: int): SettingsManager.set_no_guess_mode(idx))
    ng_row.add_child(ng_opt)
    vbox.add_child(ng_row)

    # 提示模式（对标游戏 doc10 §3.2）：标准 / 弱提示 / 禁用
    var hint_row := HBoxContainer.new()
    hint_row.add_theme_constant_override("separation", 20)
    _add_label(hint_row, "提示模式")
    var hint_opt := OptionButton.new()
    hint_opt.add_item("标准")
    hint_opt.add_item("弱提示（只给线索）")
    hint_opt.add_item("禁用提示")
    hint_opt.selected = clampi(SettingsManager.hint_mode, 0, 2)
    hint_opt.item_selected.connect(func(idx: int): SettingsManager.set_hint_mode(idx))
    hint_row.add_child(hint_opt)
    vbox.add_child(hint_row)

    # 免费提示充能：开启后提示按钮按 120 秒周期充能
    _add_check_row(vbox, "提示充能（120 秒）", func(v: bool): SettingsManager.set_hint_charge(v), SettingsManager.hint_charge)

    # 终极模式附加开关（对标 doc10 §2.3；仅在「无猜模式 = 终极」下生效）
    _add_group(vbox, "终极模式（仅「无猜模式 = 终极」生效）")
    _add_check_row(vbox, "终极：隐藏剩余雷数", func(v: bool): SettingsManager.set_ult_hide_mines(v), SettingsManager.ult_hide_mines)
    _add_check_row(vbox, "终极：隐藏可断定格数", func(v: bool): SettingsManager.set_ult_hide_deducible(v), SettingsManager.ult_hide_deducible)
    _add_check_row(vbox, "终极：卡住时自动揭星", func(v: bool): SettingsManager.set_ult_auto_reveal(v), SettingsManager.ult_auto_reveal)

    # ---------- 其他 ----------
    _add_group(vbox, "其他")
    _autosave_chk = _add_check_row(vbox, "自动存档", func(v: bool): SettingsManager.set_autosave_enabled(v), SettingsManager.autosave_enabled)
    _sfx_chk = _add_check_row(vbox, "音效", func(v: bool): SettingsManager.set_sfx_enabled(v), SettingsManager.sfx_enabled)
    # 绘画草稿是否写入存档（与设置页同项）：关闭后存档不含草稿，恢复不还原
    _add_check_row(vbox, "绘画草稿存入存档",
        func(v: bool): SettingsManager.set_drawing_in_save(v), SettingsManager.drawing_in_save)
    # 重开前确认（2026-09-25 审计补）：对局内正是 R 键误触的**发生地**，玩家想关/开它时
    # 必须能就地改 —— 此前只能退回主菜单的设置页（两套设置 UI 的唯一实质缺口）。
    _add_check_row(vbox, "重开前确认", func(v: bool): SettingsManager.set_restart_confirm(v),
        SettingsManager.restart_confirm)
    # 语音播报（2026-09-25 无障碍）：与主菜单设置页同一开关（键盘用户常在局内才想起开）
    _add_check_row(vbox, "语音播报（屏幕阅读器）", func(v: bool): SettingsManager.set_tts_enabled(v),
        SettingsManager.tts_enabled)

    var close := Button.new()
    close.text = "关闭"
    # 键盘可聚焦（2026-09-25 审计补）：对局内设置弹窗的「关闭」此前 FOCUS_NONE，
    # 而弹窗里的 CheckButton / OptionButton 本身可聚焦 —— 键盘用户能改设置却关不掉
    # 弹窗（只能按 ✕ 或点外部）。焦点样式由 _apply_theme 的 UiTheme.style_button 提供。
    close.focus_mode = Control.FOCUS_ALL
    close.custom_minimum_size = Vector2(0, 40)
    close.pressed.connect(func(): hide())
    vbox.add_child(close)

    _theme_opt.selected = THEME_MODES.find(SettingsManager.theme_mode)
    _apply_theme()


func _add_check_row(parent: Node, label: String, setter: Callable, initial: bool) -> CheckButton:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 20)
    _add_label(row, label)
    var chk := CheckButton.new()
    chk.button_pressed = initial
    chk.toggled.connect(setter)
    row.add_child(chk)
    parent.add_child(row)
    return chk


func _add_label(parent: Node, text: String) -> void:
    var lb := Label.new()
    lb.text = text
    lb.custom_minimum_size = Vector2(160, 32)
    lb.add_theme_font_size_override("font_size", 18)
    parent.add_child(lb)


## 分组标题：次级色 + 略小字号；带 meta 以便 _apply_theme 换主题时仍用次级色。
func _add_group(parent: Node, text: String) -> Label:
    var lb := Label.new()
    lb.text = text
    lb.add_theme_font_size_override("font_size", 15)
    lb.set_meta("_secondary_label", true)
    parent.add_child(lb)
    return lb


func _apply_theme() -> void:
    if _panel != null:
        var sb := StyleBoxFlat.new()
        sb.bg_color = ThemeManager.card()
        sb.set_corner_radius_all(10)
        sb.set_border_width_all(1)
        sb.border_color = ThemeManager.grid_line()
        _panel.add_theme_stylebox_override("panel", sb)
    for n in _all_controls(self):
        if n is Label:
            n.add_theme_color_override("font_color",
                ThemeManager.text_secondary() if n.has_meta("_secondary_label") else ThemeManager.text())
        elif n is Button:
            _style_button(n)


## 递归收集全部控件（弹窗体量小，无需跳过任何子树）。
func _all_controls(root: Node) -> Array:
    var out: Array = []
    for c in root.get_children():
        out.append(c)
        out.append_array(_all_controls(c))
    return out


func _style_button(btn: Button) -> void:
    UiTheme.style_button(btn)


func _on_theme_changed() -> void:
    _apply_theme()
