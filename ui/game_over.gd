# game_over.gd —— 终局结算覆盖层【plan1.1 §10.7.7-⑤】
# 文案 §8.5：胜「胜利！」/ 负「失败」；副文案「用时 {MM:SS} · 翻开 {n} 格」；
# 按钮 再玩一次 / 返回菜单。背景遮罩 §8.4.4（深 0.55 / 亮 0.35）。
extends Control

var _big_label: Label
var _sub_label: Label
var _panel: PanelContainer
var _undo_btn: Button
var _again_btn: Button


func _ready() -> void:
    add_to_group("themed")
    ThemeManager.theme_changed.connect(_on_theme_changed)
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_STOP  # 终局拦截棋盘输入（state 冻结双保险）
    hide()  # 初始隐藏（修复：否则全屏 STOP 从加载起拦截一切鼠标事件）

    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(center)
    _panel = PanelContainer.new()
    center.add_child(_panel)

    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 16)
    _panel.add_child(vbox)

    _big_label = Label.new()
    _big_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _big_label.add_theme_font_size_override("font_size", 40)
    vbox.add_child(_big_label)

    _sub_label = Label.new()
    _sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _sub_label.add_theme_font_size_override("font_size", 18)
    vbox.add_child(_sub_label)

    _undo_btn = Button.new()
    _undo_btn.text = "撤回"
    _undo_btn.focus_mode = Control.FOCUS_NONE
    _undo_btn.custom_minimum_size = Vector2(240, 44)
    _undo_btn.pressed.connect(func(): GameSession.undo())
    vbox.add_child(_undo_btn)

    _again_btn = Button.new()
    _again_btn.text = "重新开始"
    _again_btn.focus_mode = Control.FOCUS_NONE
    _again_btn.custom_minimum_size = Vector2(240, 44)
    _again_btn.pressed.connect(func(): GameSession.restart())
    vbox.add_child(_again_btn)

    var back := Button.new()
    back.text = "返回菜单"
    back.focus_mode = Control.FOCUS_NONE
    back.custom_minimum_size = Vector2(240, 44)
    back.pressed.connect(func():
        SaveCoordinator.clear()
        get_tree().change_scene_to_file("res://ui/main_menu.tscn"))
    vbox.add_child(back)

    GameSession.game_ended.connect(_on_game_ended)
    # 重新开始 / 撤回后隐藏终局覆盖层（否则遮住新棋盘 → 「再来一次没反应」）
    if not GameSession.session_started.is_connected(_on_hide):
        GameSession.session_started.connect(_on_hide)
    if not GameSession.session_restored.is_connected(_on_hide):
        GameSession.session_restored.connect(_on_hide)
    visible = false
    _apply_theme()


func _on_game_ended(won: bool) -> void:
    visible = true
    _big_label.text = "胜利！" if won else "失败"
    if _undo_btn != null:
        _undo_btn.visible = not won  # 撤回仅在失败终局可用
    var board: Board = GameSession.board
    var revealed_n: int = board.get_stats()["revealed"] if board != null else 0
    var total: int = int(GameSession.elapsed)
    var m: int = total / 60
    var s: int = total % 60
    _sub_label.text = "用时 %02d:%02d · 翻开 %d 格" % [m, s, revealed_n]
    _apply_theme()


## 重新开始 / 撤回后隐藏终局覆盖层。
func _on_hide() -> void:
    visible = false


func _apply_theme() -> void:
    # 终局遮罩（§8.4.4）
    var dim := ThemeManager.endgame_dim()
    if _panel != null:
        var sb := StyleBoxFlat.new()
        sb.bg_color = ThemeManager.card()
        sb.set_corner_radius_all(10)
        _panel.add_theme_stylebox_override("panel", sb)
        _big_label.add_theme_color_override("font_color", ThemeManager.text())
        _sub_label.add_theme_color_override("font_color", ThemeManager.text_secondary())
        for n in _panel.get_children():
            if n is VBoxContainer:
                for c in n.get_children():
                    if c is Button:
                        _style_button(c)
    _draw_dim = dim
    queue_redraw()


var _draw_dim: Color = Color(0, 0, 0, 0.55)


func _draw() -> void:
    draw_rect(Rect2(Vector2.ZERO, size), _draw_dim)


func _style_button(btn: Button) -> void:
    UiTheme.style_button(btn)


func _on_theme_changed() -> void:
    _apply_theme()
