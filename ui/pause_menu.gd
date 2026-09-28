# pause_menu.gd —— 对局暂停面板
#
# 背景：GameSession 里 State.PAUSED 与 set_paused() 一直是**接线了但没人调用**的死代码
# （只有 unit 测试在用），生产 UI 没有任何暂停入口，也没有 ESC。
# 本面板给暂停一个真实入口：暂停期间计时停止、棋盘输入冻结（session 状态机已保证）。
#
# 与 settings_popup 同构：PopupPanel + PanelContainer 承载主题样式。
extends PopupPanel

# 2026-09-28：`restart_requested` 信号随「重新开始」按钮一并删除（它本就无人接线；
# 进行中重开已按用户决策整体移除）。

var _panel: PanelContainer
var _sub_label: Label


func _ready() -> void:
    add_to_group("themed")
    ThemeManager.theme_changed.connect(_on_theme_changed)
    exclusive = true      # 阻止点击穿透到棋盘
    popup_hide.connect(_on_popup_hide)
    _build_ui()


func _build_ui() -> void:
    _panel = PanelContainer.new()
    add_child(_panel)

    var margin := MarginContainer.new()
    for side in ["margin_left", "margin_right"]:
        margin.add_theme_constant_override(side, 24)
    margin.add_theme_constant_override("margin_top", 20)
    margin.add_theme_constant_override("margin_bottom", 20)
    _panel.add_child(margin)

    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 12)
    vbox.custom_minimum_size = Vector2(300, 0)
    margin.add_child(vbox)

    @warning_ignore("shadowed_variable_base_class")
    var title := Label.new()
    title.text = "已暂停"
    title.add_theme_font_size_override("font_size", 26)
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    vbox.add_child(title)

    _sub_label = Label.new()
    _sub_label.add_theme_font_size_override("font_size", 16)
    _sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    vbox.add_child(_sub_label)

    vbox.add_child(HSeparator.new())

    _add_button(vbox, "继续游戏", func(): hide())
    # 2026-09-28（用户决策）：删除「重新开始」与「主菜单」两个按钮——
    # 进行中重开已整体移除（HUD 按钮 / R 键同步删）；主菜单场景已删除，
    # 「关卡列表」是唯一的离开出口（保存进度 + 回选关页）。
    # 离开不再弹确认（2026-09-22 用户决策）：直接落盘 + 离开。
    # v3.2 起这里就是「保存而非放弃」，确认框对玩家只剩打断作用（实测反馈：很烦）；
    # HUD 直点按钮同步改掉后，整个离开路径统一为 save_now + 切场景。
    _add_button(vbox, "关卡列表", func():
        hide()
        _resume()
        # 离开对局不删档——立即落盘当前进度（含绘画草稿），
        # 下次进入本关/下次启动时自动恢复（存档内容自动保存）。
        GameSession.save_now()
        get_tree().change_scene_to_file("res://ui/level_select.tscn"))

    _apply_theme()


## 面板显示时刷新「已用时」（暂停期间该值冻结）。
func popup_center_refreshed() -> void:
    if _sub_label != null and GameSession != null:
        var total := int(GameSession.elapsed)
        # 【09-28 审计修复 A8】int/int 显式化（与 hud.gd 同口径）
        _sub_label.text = "已用时 %02d:%02d · 计时已停止" % [floori(total / 60.0), total % 60]
    popup_centered()


func _add_button(parent: Node, text: String, on_pressed: Callable) -> void:
    var b := Button.new()
    b.text = text
    # 键盘可聚焦（2026-09-25 审计补）：暂停菜单此前按钮一律 FOCUS_NONE —— 键盘用户
    # 能按 Esc 暂停却**没法用键盘继续**（只能 Esc 或鼠标点）。焦点样式由
    # _apply_theme 里的 UiTheme.style_button 提供（该文件 122 行）。
    b.focus_mode = Control.FOCUS_ALL
    b.custom_minimum_size = Vector2(0, 44)
    b.pressed.connect(on_pressed)
    parent.add_child(b)


## 关闭面板（含 ESC / 点关闭）一律恢复对局，避免「暂停后卡住不知道怎么回去」。
func _on_popup_hide() -> void:
    _resume()


func _resume() -> void:
    if GameSession.state == GameSession.State.PAUSED:
        GameSession.set_paused(false)


func _apply_theme() -> void:
    if _panel == null:
        return
    var sb := StyleBoxFlat.new()
    sb.bg_color = ThemeManager.card()
    sb.set_corner_radius_all(10)
    sb.set_border_width_all(1)
    sb.border_color = ThemeManager.grid_line()
    _panel.add_theme_stylebox_override("panel", sb)
    for n in _all_controls(self):
        if n is Label:
            n.add_theme_color_override("font_color",
                    ThemeManager.text_secondary() if n == _sub_label else ThemeManager.text())
        elif n is Button:
            UiTheme.style_button(n)


func _all_controls(root: Node) -> Array:
    var out: Array = []
    for c in root.get_children():
        out.append(c)
        out.append_array(_all_controls(c))
    return out


func _on_theme_changed() -> void:
    _apply_theme()
