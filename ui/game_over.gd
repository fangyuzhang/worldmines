# game_over.gd —— 终局结算覆盖层【plan1.1 §10.7.7-⑤】
# 文案 §8.5：胜「胜利！」/ 负「失败」；副文案「用时 {MM:SS} · 翻开 {n} 格」；
# 按钮 再玩一次 / 返回菜单。背景遮罩 §8.4.4（深 0.55 / 亮 0.35）。
extends Control

var _big_label: Label
var _sub_label: Label
var _panel: PanelContainer
var _undo_btn: Button
var _next_btn: Button
var _skip_btn: Button
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

    # 失败后的出路：跳过本关直接推进序列（解锁下一关，但不计通关）。
    # 与「下一关」对称：胜利给前进、失败给绕行，两者都不必退回选关页重走。
    _skip_btn = Button.new()
    _skip_btn.text = "跳过本关"
    _skip_btn.focus_mode = Control.FOCUS_NONE
    _skip_btn.custom_minimum_size = Vector2(240, 44)
    _skip_btn.pressed.connect(_on_skip_level)
    vbox.add_child(_skip_btn)

    # 通关后直接进入下一关（原先只有「重新开始 / 返回菜单」，
    # 而关卡解锁依赖「通关上一关」，玩家每次都得手动退回选关页重走一遍）。
    _next_btn = Button.new()
    _next_btn.text = "下一关"
    _next_btn.focus_mode = Control.FOCUS_NONE
    _next_btn.custom_minimum_size = Vector2(240, 44)
    _next_btn.pressed.connect(_on_next_level)
    vbox.add_child(_next_btn)

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
    # 下一关：只有「生成关卡序列」里的关卡才知道下一关是谁（见 LevelSequence）。
    # 手工关（res://levels/…）没有序列概念 → 不提供该入口。
    # 下一关的落点（跨尺寸）：本尺寸打完接下一个尺寸的第 1 关，直到 9×9 末关为止。
    var next_pos := LevelSequence.advance(GameSession.level_path)
    var cur_pos := LevelSequence.parse_path(GameSession.level_path)
    if _next_btn != null:
        _next_btn.visible = won and LevelSequence.has_next(GameSession.level_path)
        # 跨尺寸时把目标写进按钮文案：让玩家知道点下去是「进 6×6」而不是又一张同尺寸图
        if not next_pos.is_empty() and int(next_pos["size"]) != int(cur_pos.get("size", 0)):
            _next_btn.text = "进入 %d×%d" % [int(next_pos["size"]), int(next_pos["size"])]
        else:
            _next_btn.text = "下一关"
    # 跳过：失败才有（胜利已给「下一关」），只对生成序列关卡提供。
    # 用 has_skip_target 而非 has_next——后者要求「当前关已通关」，
    # 而失败终局当前关必然未通关，用它按钮永远不会出现。
    #
    # 真的没有下一关（9×9 末关）：按钮**仍然显示**但置灰 + 改文案，
    # 否则玩家看到的是「按需求该有的按钮凭空不见了」（实测反馈过这种困惑）
    # ——没出路和没按钮，前者至少说明了原因。
    if _skip_btn != null:
        _skip_btn.visible = (not won) and not cur_pos.is_empty()
        _skip_btn.disabled = next_pos.is_empty()
        _skip_btn.text = "跳过本关" if not next_pos.is_empty() else "已是最后一关"
    var board: Board = GameSession.board
    var revealed_n: int = board.get_stats()["revealed"] if board != null else 0
    var total: int = int(GameSession.elapsed)
    var m: int = total / 60
    var s: int = total % 60
    _sub_label.text = "用时 %02d:%02d · 翻开 %d 格" % [m, s, revealed_n]
    _apply_theme()


## 前往下一关（可能跨尺寸：本尺寸打完接下一个尺寸的第 1 关）。
## 生成流程归选关页管（它才知道怎么生成/缓存关卡文件），这里只交接意图；
## auto_start=true 让选关页接着**直接开局**——否则玩家点「下一关」只是回到选关页，
## 还得再点一次「开始游戏」（实测反馈：这不叫「到下一关」）。
func _on_next_level() -> void:
    var pos := LevelSequence.advance(GameSession.level_path)
    if pos.is_empty():
        return
    # tier：关卡库关卡跨档时必须带上（否则选关页落回默认档、开局错关）；生成关为空串
    LevelSequence.request_focus(str(pos["mode"]), int(pos["size"]), true, str(pos.get("tier", "")))
    SaveCoordinator.clear()
    get_tree().change_scene_to_file("res://ui/level_select.tscn")


## 跳过本关（失败终局）：记为 skipped → 解锁下一关 → 直接开局下一关（可能跨尺寸）。
## 与「下一关」共用同一条导航路径（意图交接给选关页），区别只在进度写法：
## 跳过不写 cleared，所以通关统计与最佳用时不受影响，玩家回头补通后标记自动转 ✓。
func _on_skip_level() -> void:
    var pos := LevelSequence.advance(GameSession.level_path)
    if pos.is_empty():
        return  # 最后一关（按钮已置灰，这里是防御）
    LevelSequence.skip_to_next(GameSession.level_path)
    LevelSequence.request_focus(str(pos["mode"]), int(pos["size"]), true, str(pos.get("tier", "")))
    SaveCoordinator.clear()
    get_tree().change_scene_to_file("res://ui/level_select.tscn")


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
