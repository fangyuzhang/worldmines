# level_select.gd —— 关卡选择（动态列表）【plan1.1 §10.7.7-②】
# 文案 §8.5：标题「选择关卡」，按钮「返回」，关卡条目 = JSON name / 文件名。
# start_level 失败不切场景 + toast「关卡加载失败」；空列表显示「未找到可用关卡」。
extends Control


func _ready() -> void:
    add_to_group("themed")
    ThemeManager.theme_changed.connect(_on_theme_changed)
    _build_ui()


func _build_ui() -> void:
    # 顶栏：标题 + 返回
    var top := HBoxContainer.new()
    top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    top.offset_top = 12
    top.add_theme_constant_override("separation", 16)
    add_child(top)

    var title := Label.new()
    title.text = "选择关卡"
    title.add_theme_font_size_override("font_size", 28)
    top.add_child(title)

    var summary := Label.new()
    summary.text = "已通关 %d / %d" % [ProgressStore.cleared_count(), LevelLoader.list_levels().size()]
    summary.add_theme_font_size_override("font_size", 18)
    summary.size_flags_horizontal = Control.SIZE_EXPAND
    top.add_child(summary)

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

    # 滚动列表
    var scroll := ScrollContainer.new()
    scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    scroll.offset_top = 64
    scroll.offset_bottom = -16
    scroll.offset_left = 320
    scroll.offset_right = -320
    add_child(scroll)

    var vbox := VBoxContainer.new()
    vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(vbox)

    # 动态填充关卡：按变体类别分组浏览（经典 / 布局型 / 线索型 / 一布局一线索 / 线索混合 / 双布局）
    var levels := LevelLoader.list_levels()
    if levels.is_empty():
        var empty_lb := Label.new()
        empty_lb.text = "未找到可用关卡"
        empty_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        vbox.add_child(empty_lb)
        push_error("关卡列表为空（LevelLoader.list_levels 为空）")
    for g in _group_levels(levels):
        var header := Label.new()
        header.text = "%s（%d 关）" % [g["name"], g["paths"].size()]
        header.add_theme_font_size_override("font_size", 20)
        header.custom_minimum_size = Vector2(0, 38)
        vbox.add_child(header)
        for path in g["paths"]:
            vbox.add_child(_make_level_button(path))

    # 模组关卡（已加载 mod 生成的关卡，user://mods/*/levels/）
    var mod_levels := LevelLoader.list_mod_levels()
    if not mod_levels.is_empty():
        var mheader := Label.new()
        mheader.text = "模组关卡（%d 关）" % mod_levels.size()
        mheader.add_theme_font_size_override("font_size", 20)
        mheader.custom_minimum_size = Vector2(0, 38)
        vbox.add_child(mheader)
        for path in mod_levels:
            vbox.add_child(_make_level_button(path))

    _apply_theme()


## 秒 → M:SS.d（进度最佳用时展示）
func _fmt_time(seconds: float) -> String:
    if seconds < 0.0:
        return "--"
    var m: int = int(seconds) / 60
    var s: float = seconds - float(m * 60)
    return "%d:%04.1f" % [m, s]


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


## 按变体类别分组关卡（保持固定类别顺序 + 类内文件名顺序）。
func _group_levels(levels: Array) -> Array:
    var order := ["经典", "布局型", "线索型", "一布局一线索", "线索混合", "双布局"]
    var buckets := {}
    for path in levels:
        var cat := LevelLoader.classify_variant(path)
        if not buckets.has(cat):
            buckets[cat] = []
        buckets[cat].append(path)
    var out: Array = []
    for c in order:
        if buckets.has(c):
            out.append({"name": c, "paths": buckets[c]})
    return out


## 关卡按钮（点击加载关卡并切入对局）。
## 关卡按钮（点击加载关卡并切入对局）。已通关的显示 ✓ 与最佳用时。
func _make_level_button(path: String) -> Button:
    var btn := Button.new()
    var text := LevelLoader.get_level_name(path)
    if ProgressStore.is_cleared(path):
        var best := ProgressStore.best_time(path)
        text += "  ✓ 最佳 %s" % _fmt_time(best)
    btn.text = text
    btn.focus_mode = Control.FOCUS_NONE
    btn.custom_minimum_size = Vector2(360, 44)
    btn.pressed.connect(func():
        if GameSession.start_level(path):
            get_tree().change_scene_to_file("res://ui/board_view.tscn")
        else:
            _toast("关卡加载失败"))
    return btn


func _apply_theme() -> void:
    for n in get_children():
        if n is HBoxContainer:
            for c in n.get_children():
                if c is Label:
                    c.add_theme_color_override("font_color", ThemeManager.text())
                elif c is Button:
                    _style_button(c)
        elif n is ScrollContainer:
            for sc in n.get_children():
                if sc is VBoxContainer:
                    for c in sc.get_children():
                        if c is Button:
                            _style_button(c)
                        elif c is Label:
                            c.add_theme_color_override("font_color", ThemeManager.text_secondary())
    queue_redraw()


func _style_button(btn: Button) -> void:
    UiTheme.style_button(btn)


func _on_theme_changed() -> void:
    _apply_theme()
