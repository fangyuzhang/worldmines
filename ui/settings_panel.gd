# settings_panel.gd —— 设置面板（分页：画面 / 玩法 / 音效 / 皮肤 / 数据，实时生效 + 持久化）
#
# 信息结构（v3.4 重构）：
#   原先把 9 个设置项 + 通关进度全挤在一页「通用」，玩家要在一长串开关里逐行找目标项。
#   现按「改完会立刻影响什么」分页（分类标准是玩家的找法，不是代码字段分组）：
#     · 画面：外观 / 显示类——主题、全屏、悬停高亮、翻开动效、绘画层透明度、界面缩放
#     · 玩法：对局规则与操作——连携、自动存档、键盘、重开确认、无猜、提示三档、提示充能、终极三项
#     · 音效：音效总开关（AudioManager 无 volume_db / bus 音量能力 → 不提供音量条，见交付报告）
#     · 皮肤：保留独立 skin_browser.tscn（自带主题刷新）
#     · 数据：绘画草稿入档 / 清除通关进度 / 清除全部草稿
#   键盘操作（任务表未点名）按语义归「玩法」——它改的是输入方式，不是画面观感。
#
# ⚠️ 维护约定：_apply_theme() 走递归遍历（见文件末），新增页签 / 分组无需再改它；
#    早期硬编码层级（CenterContainer→PanelContainer→TabContainer→VBox→row）会在新页签里漏刷配色。
extends Control

# 顶层承载卡片：_apply_theme 需要给它刷 stylebox —— 存引用比按层级遍历耐用。
var _panel: PanelContainer
# 页签容器：**自带一块不透明的 `panel` 样式盒**铺在内容区底下（页签条下面那整块）。
# 递归上色只认 Label / Button ⇒ 结构上够不到它，必须存引用单独刷（见 _style_tabs）。
var _tabs: TabContainer
# 皮肤页引用：其内部自带 theme_changed 处理，递归上色时要跳过（见 _collect_controls）。
var _skin_page: Control

# ---- 画面页 ----
var _theme_opt: OptionButton
var _fullscreen_chk: CheckButton
var _hover_chk: CheckButton
var _ripple_chk: CheckButton
var _opacity_slider: HSlider
var _ui_scale_opt: OptionButton

# ---- 玩法页 ----
var _quick_chk: CheckButton
var _question_chk: CheckButton
var _autosave_chk: CheckButton
var _keyboard_chk: CheckButton
# 2026-09-28：`_restart_confirm_chk` 随「重开前确认」行一并移除（进行中重开已删）。
var _no_guess_opt: OptionButton
var _hint_mode_opt: OptionButton
# 2026-09-28：`_hint_charge_chk` 随「提示充能」行移除（提示改为不消耗）。
var _ult_hide_mines_chk: CheckButton
var _ult_hide_deducible_chk: CheckButton
var _ult_auto_reveal_chk: CheckButton

# ---- 音效页 ----
var _sfx_chk: CheckButton

# ---- 数据页 ----
var _drawing_save_chk: CheckButton

## 面板固定尺寸（v3.5）：TabContainer 的默认尺寸随当前页内容变化（玩法页 8 项 vs
## 音效页 1 项），外面又是 CenterContainer 居中 → 切页时尺寸连位置一起漂移。
## 钉死这个尺寸后，切页只换内容、外框不动；内容超出由各页 ScrollContainer 顶上。
## 高 520 是权衡：能完整装下最长的玩法页（含小节标题），再高会顶到标题栏与返回按钮。
const PANEL_SIZE := Vector2(820, 520)

## 界面缩放档位（与 SettingsManager.ui_scale 一一对应）
const UI_SCALES := [1.0, 1.25, 1.5]
const UI_SCALE_LABELS := ["100%", "125%", "150%"]
## 主题下拉的取值表**不再自带副本** —— 见 _build_video_page：直接读 ThemeManager.THEME_IDS。
## 原 `THEME_MODES := ["system","dark","light"]` 与三行 add_item() 是同一事实的两份副本，
## 2026-09-29 接入 CozyStyle 五主题时合并为一份（唯一事实源在 ThemeManager）。


func _ready() -> void:
    add_to_group("themed")
    ThemeManager.theme_changed.connect(_on_theme_changed)
    _build_ui()


func _build_ui() -> void:
    var top := HBoxContainer.new()
    top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    top.offset_top = 12
    # 左右边距 24 = 本工程的页面基线（rules 图鉴页与对局 HUD 都是 24/24）。
    # 原先只给 offset_top，左端默认 0 ⇒ 标题「设置」贴着窗口左边缘，而右端的
    # 「返回」按钮自带 offset_right = -24，同一条顶栏左右边距不对称。
    top.offset_left = 24
    top.offset_right = -24
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
    back.pressed.connect(func(): get_tree().change_scene_to_file("res://ui/level_select.tscn"))
    add_child(back)

    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    center.offset_top = 64
    add_child(center)

    _panel = PanelContainer.new()
    center.add_child(_panel)

    var tabs := TabContainer.new()
    _tabs = tabs   # 存引用：_apply_theme 要单独给它刷 stylebox（见 _style_tabs 的说明）
    # 固定面板尺寸（v3.5）：TabContainer 的默认尺寸**由当前页内容决定** —— 玩法页 8 项、
    # 音效页 1 项，切页时面板忽大忽小，外面又是 CenterContainer 居中，于是尺寸连着位置
    # 一起漂移（玩家视角：换个选项卡整个界面就抖一下）。显式钉死尺寸后，切页只换内容、
    # 不动外框。内容超出由各页自带的 ScrollContainer 顶上（见 _make_page）。
    tabs.custom_minimum_size = PANEL_SIZE
    _panel.add_child(tabs)

    # 页签顺序 = 玩家使用频次：画面 / 玩法（高频）→ 音效 / 皮肤 / 数据（低频）
    var video_page := _make_page("画面")
    tabs.add_child(video_page)
    var play_page := _make_page("玩法")
    tabs.add_child(play_page)
    # 按键页（2026-09-25 无障碍审计）：键位重绑定，此前全部硬编码、Dvorak/单手玩家无解。
    var keys_page := _make_page("按键")
    tabs.add_child(keys_page)
    var audio_page := _make_page("音效")
    tabs.add_child(audio_page)

    _skin_page = load("res://ui/skin_browser.tscn").instantiate()
    _skin_page.name = "皮肤"
    tabs.add_child(_skin_page)

    var data_page := _make_page("数据")
    tabs.add_child(data_page)

    # 注：_make_page 返回外层 ScrollContainer，往里填行走它的第 0 个子节点（VBoxContainer）
    _build_video_page(video_page.get_child(0) as VBoxContainer)
    _build_play_page(play_page.get_child(0) as VBoxContainer)
    _build_keys_page(keys_page.get_child(0) as VBoxContainer)
    _build_audio_page(audio_page.get_child(0) as VBoxContainer)
    _build_data_page(data_page.get_child(0) as VBoxContainer)

    # 全部页填完之后再统一各页的标签列宽 —— 必须等所有行都在场才能量出"最宽的那条"
    #（见 _align_label_column：写死宽度的做法在这里必然失配）。
    for i in tabs.get_tab_count():
        _align_label_column(tabs.get_child(i))

    _apply_theme()


## 建立一页：外层 ScrollContainer + 内层 VBoxContainer（返回内层，调用方往上填行）。
## 页签名挂在**外层**（TabContainer 按子节点 name 取页签名）。
##
## 为什么每页都要包一层滚动：面板尺寸已固定（见 _build_ui 的 tabs.custom_minimum_size），
## 而各页项数差别很大（玩法页 8 项、音效页 1 项）。不包滚动的话，高页会被裁掉且
## **没有任何办法访问被裁掉的部分**——固定尺寸一旦配上不定长内容，滚动就是必需品。
func _make_page(page_name: String) -> ScrollContainer:
    var scroll := ScrollContainer.new()
    scroll.name = page_name
    var vbox := VBoxContainer.new()
    vbox.name = page_name + "_inner"
    vbox.add_theme_constant_override("separation", 14)
    vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(vbox)
    return scroll


# ============================ 画面 ============================

func _build_video_page(page: VBoxContainer) -> void:
    # 主题模式（跟随系统 / 旧深色 / 旧亮色 / CozyStyle 五主题）
    #
    # 【2026-09-29】原先这里硬编码两份副本：`THEME_MODES` 常量 + 三行 add_item("跟随系统"/"深色"/"亮色")。
    # 接入 CozyStyle 后主题从 3 个变成 8 个，两处都要改、且显示名还散在 if 分支里 —— 典型漂移点。
    # 现在改成**按 ThemeManager.THEME_IDS 渲染**（唯一事实源），显示名统一走 theme_label()。
    # 顺序由 THEME_IDS 决定：system 恒在 0 位（test_settings_grouping 的 selected 索引断言依赖这点）。
    var theme_row := HBoxContainer.new()
    theme_row.add_theme_constant_override("separation", 24)
    _add_label(theme_row, "主题模式")
    _theme_opt = OptionButton.new()
    var theme_ids: Array = ThemeManager.THEME_IDS
    for i in theme_ids.size():
        var tid := str(theme_ids[i])
        _theme_opt.add_item(ThemeManager.theme_label(tid))
        # 浅色系（CozyStyle 与旧亮色）在深色下拉弹层里要标明，避免选完才发现是亮的；
        # 这里只做文案标注，不参与逻辑判定。
        if tid != "system" and tid != "dark":
            _theme_opt.set_item_tooltip(i, "浅色系主题")
    _theme_opt.item_selected.connect(func(idx: int):
        SettingsManager.set_theme_mode(str(theme_ids[idx])))
    # 存档里的脏 id（手改 settings.cfg / 旧版本遗留）→ 落回 0 位（跟随系统），而不是让下拉停在 -1
    var sel: int = theme_ids.find(SettingsManager.theme_mode)
    _theme_opt.selected = sel if sel >= 0 else 0
    theme_row.add_child(_theme_opt)
    page.add_child(theme_row)

    # 全屏模式：勾选 = 独占全屏（无边框）；取消 = 窗口模式（可自由调整大小）
    _fullscreen_chk = _add_check_row(page, "全屏模式",
        func(v: bool): SettingsManager.set_fullscreen(v), SettingsManager.fullscreen)
    # 悬停邻域高亮
    _hover_chk = _add_check_row(page, "悬停邻域高亮",
        func(v: bool): SettingsManager.set_hover_highlight(v), SettingsManager.hover_highlight)
    # 翻开动效总闸（波浪 + 后续单格 pop）：唯一开关，标签即语义（test_reveal_effects 锚定此文案）
    _ripple_chk = _add_check_row(page, "翻开动效（波浪 / 单格）",
        func(v: bool): SettingsManager.set_ripple_enabled(v), SettingsManager.ripple_enabled)

    # 绘画层透明度（0.5~1.0）—— 分工不可合并：
    # value_changed 每刻度触发 → 只 apply 不落盘；drag_ended（松手）才 save 一次。
    # 若两处都调 set_drawing_opacity，一次拖动会全量写盘几十次（原 popup 已踩过此坑）。
    var op_row := HBoxContainer.new()
    op_row.add_theme_constant_override("separation", 24)
    _add_label(op_row, "绘画层透明度")
    _opacity_slider = HSlider.new()
    _opacity_slider.min_value = 0.5
    _opacity_slider.max_value = 1.0
    _opacity_slider.step = 0.05
    _opacity_slider.value = SettingsManager.drawing_opacity
    _opacity_slider.custom_minimum_size = Vector2(180, 24)
    _opacity_slider.value_changed.connect(func(v: float): SettingsManager.apply_drawing_opacity(v))
    _opacity_slider.drag_ended.connect(func(_changed: bool): SettingsManager.save())
    op_row.add_child(_opacity_slider)
    page.add_child(op_row)

    # 界面缩放（任务三调研结论：改动只涉及 _apply_content_scale + 一个新字段，可做）
    var scale_row := HBoxContainer.new()
    scale_row.add_theme_constant_override("separation", 24)
    _add_label(scale_row, "界面缩放")
    _ui_scale_opt = OptionButton.new()
    for lb in UI_SCALE_LABELS:
        _ui_scale_opt.add_item(lb)
    _ui_scale_opt.item_selected.connect(func(idx: int):
        SettingsManager.set_ui_scale(UI_SCALES[idx]))
    _ui_scale_opt.selected = _closest_scale_index(SettingsManager.ui_scale)
    scale_row.add_child(_ui_scale_opt)
    page.add_child(scale_row)


# ============================ 玩法 ============================

func _build_play_page(page: VBoxContainer) -> void:
    # 连携操作：一键展开（chord）+ 右键拖动插旗。默认开；误触多可关
    _quick_chk = _add_check_row(page, "连携操作（一键展开 / 拖动插旗）",
        func(v: bool): SettingsManager.set_quick_actions(v), SettingsManager.quick_actions)
    # 右键「? 」三态：默认关 → 右键只有 标雷 / 取消 两态（见 SettingsManager 的同名字段注释）。
    # 标签写全循环顺序，是为了让玩家一眼知道开/关各自得到什么，而不是猜「问号」指什么。
    _question_chk = _add_check_row(page, "右键可标问号（标雷 → ？ → 取消）",
        func(v: bool): SettingsManager.set_question_mark_enabled(v),
        SettingsManager.question_mark_enabled)
    _autosave_chk = _add_check_row(page, "自动存档",
        func(v: bool): SettingsManager.set_autosave_enabled(v), SettingsManager.autosave_enabled)
    # 键盘操作：关闭 = 只用鼠标
    _keyboard_chk = _add_check_row(page, "键盘操作",
        func(v: bool): SettingsManager.set_keyboard_enabled(v), SettingsManager.keyboard_enabled)
    # 重开前确认：玩家在重开弹窗勾「不再提示」后会被置 false —— 本项是唯一的改回入口
    # 2026-09-28 移除「重开前确认」行：进行中重开已删（用户决策），该确认框与开关失去对应场景。
    # SettingsManager.restart_confirm 属性保留不删——存档兼容，且终局重开若将来要加确认可直接复用。
    # 语音播报（2026-09-25 无障碍）：棋盘内容纯 _draw 绘制、屏幕阅读器读不到 ——
    # 开启后键盘操作会播报光标格的位置与状态（键盘用户正是本项的目标人群）。
    _add_check_row(page, "语音播报（屏幕阅读器）",
        func(v: bool): SettingsManager.set_tts_enabled(v), SettingsManager.tts_enabled)

    # 无猜模式（对标 doc10 §2；核心玩法开关，此前只能改配置文件）：关闭 / 专家 / 终极
    _no_guess_opt = _add_opt_row(page, "无猜模式")
    _no_guess_opt.add_item("关闭")
    _no_guess_opt.add_item("专家（禁止猜测）")
    _no_guess_opt.add_item("终极（新线索打星号）")
    _no_guess_opt.item_selected.connect(func(idx: int): SettingsManager.set_no_guess_mode(idx))
    _no_guess_opt.selected = clampi(SettingsManager.no_guess_mode, 0, 2)

    # 提示三档（对标 doc10 §3.2；此前只能改配置文件）
    _hint_mode_opt = _add_opt_row(page, "提示模式")
    _hint_mode_opt.add_item("标准")
    _hint_mode_opt.add_item("弱提示（只给线索）")
    _hint_mode_opt.add_item("禁用提示")
    _hint_mode_opt.item_selected.connect(func(idx: int): SettingsManager.set_hint_mode(idx))
    _hint_mode_opt.selected = clampi(SettingsManager.hint_mode, 0, 2)

    # 2026-09-28 移除「提示充能（120 秒）」：提示改为每次只给 ≤2 格且**不消耗**（用户决策），
    # 充能机制整体退役（SettingsManager.hint_charge 属性保留仅为存档兼容，无 UI 面）。

    # 终极模式三项：只在「无猜模式 = 终极」的关卡里起作用 —— 必须标注，否则玩家会困惑
    _add_section_label(page, "终极模式附加开关（仅「无猜模式 = 终极」时生效）")
    _ult_hide_mines_chk = _add_check_row(page, "终极：隐藏剩余雷数",
        func(v: bool): SettingsManager.set_ult_hide_mines(v), SettingsManager.ult_hide_mines)
    _ult_hide_deducible_chk = _add_check_row(page, "终极：隐藏可断定格数",
        func(v: bool): SettingsManager.set_ult_hide_deducible(v), SettingsManager.ult_hide_deducible)
    _ult_auto_reveal_chk = _add_check_row(page, "终极：卡住时自动揭星",
        func(v: bool): SettingsManager.set_ult_auto_reveal(v), SettingsManager.ult_auto_reveal)


# ============================ 按键（2026-09-25 无障碍审计新增）============================

## action -> Button（显示当前键位；点击进入捕获态）
var _key_rows: Dictionary = {}
## 正在等待玩家按下新键的动作（"" = 未捕获）。捕获期间本页 `_input` 优先消费按键。
var _capturing_action := ""


func _build_keys_page(page: VBoxContainer) -> void:
    _add_section_label(page, "对局快捷键（点右侧按钮，再按下新键；Esc 取消，Del 恢复该项默认）")
    _key_rows.clear()
    for action: String in SettingsManager.DEFAULT_KEYS:
        var row := HBoxContainer.new()
        row.add_theme_constant_override("separation", 24)
        _add_label(row, str(SettingsManager.KEY_ACTION_LABELS.get(action, action)))
        var btn := Button.new()
        btn.text = SettingsManager.key_label(SettingsManager.key_for(action))
        btn.focus_mode = Control.FOCUS_ALL
        btn.custom_minimum_size = Vector2(140, 32)
        btn.set_meta("key_action", action)      # 测试 / 调试可据此定位
        btn.pressed.connect(_on_key_bind_pressed.bind(action))
        row.add_child(btn)
        page.add_child(row)
        _key_rows[action] = btn
    _add_section_label(page, "方向键（移动）、回车（翻开）与 Home / End / PageUp / PageDown（跳行）"
        + "始终可用 —— 它们不参与重绑定，保证改键后导航能力不会丢。")
    _add_button_row(page, "恢复默认键位", "恢复默认", func():
        SettingsManager.reset_key_bindings()
        _refresh_key_rows()
        _toast("已恢复默认键位", false))


func _on_key_bind_pressed(action: String) -> void:
    _capturing_action = action
    _refresh_key_rows()
    _toast("请按下新的按键（Esc 取消 / Del 恢复该项默认）", false)


func _refresh_key_rows() -> void:
    for action: String in _key_rows:
        var btn: Button = _key_rows[action]
        if not is_instance_valid(btn):
            continue
        btn.text = "按新键…" if action == _capturing_action \
            else SettingsManager.key_label(SettingsManager.key_for(action))


## 捕获阶段消费按键。用 `_input`（比 GUI 更早收到按键），只在捕获中才动作 ——
## 平时立刻返回，不影响页面其它交互。
func _input(event: InputEvent) -> void:
    if _capturing_action == "":
        return
    # 捕获期间点鼠标 = 放弃捕获（否则"点了改键又去点别处"会让下一次按键被无辜吞掉）
    if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
        _capturing_action = ""
        _refresh_key_rows()
        return
    if not (event is InputEventKey) or not event.pressed:
        return
    var kc: int = (event as InputEventKey).keycode
    if kc == KEY_ESCAPE:
        _capturing_action = ""      # Esc = 取消捕获（不改变绑定）
        _refresh_key_rows()
        return
    get_viewport().set_input_as_handled()
    var act := _capturing_action
    _capturing_action = ""
    if kc == KEY_DELETE or kc == KEY_BACKSPACE:
        SettingsManager.reset_key_binding(act)
        _toast("已恢复「%s」的默认键" % str(SettingsManager.KEY_ACTION_LABELS.get(act, act)), false)
    elif SettingsManager.is_reserved_key(kc):
        _toast("方向键 / 回车 / 翻页键是保留键，不能占用", true)
    else:
        var other := SettingsManager.key_conflict(act, kc)
        if other != "":
            _toast("「%s」已占用该键 —— 先改它再绑这里"
                % str(SettingsManager.KEY_ACTION_LABELS.get(other, other)), true)
        else:
            SettingsManager.set_key_binding(act, kc)
    _refresh_key_rows()


# ============================ 音效 ============================

func _build_audio_page(page: VBoxContainer) -> void:
    # AudioManager 只暴露 enabled（无 volume_db / bus 音量能力），按「不为设置项新造子系统」
    # 原则不提供音量条——除非未来 AudioManager 增加音量 API，此处再补滑条。
    _sfx_chk = _add_check_row(page, "音效",
        func(v: bool): SettingsManager.set_sfx_enabled(v), SettingsManager.sfx_enabled)


# ============================ 数据 ============================

func _build_data_page(page: VBoxContainer) -> void:
    # 绘画草稿是否写入存档：关闭后存档不含草稿，恢复对局也不还原
    _drawing_save_chk = _add_check_row(page, "绘画草稿存入存档",
        func(v: bool): SettingsManager.set_drawing_in_save(v), SettingsManager.drawing_in_save)

    _add_button_row(page, "通关进度", "清除…", _on_clear_progress)
    # 清除全部绘画草稿：复用 SaveCoordinator.clear_all_drawings()（已具备的 API，不新造子系统）
    _add_button_row(page, "绘画草稿", "清除全部…", _on_clear_drawings)


## 清除全部通关进度（二次确认，避免误触）
func _on_clear_progress() -> void:
    _confirm("清除全部通关进度（不可恢复）？", "清除", func():
        ProgressStore.clear_all()
        _toast("通关进度已清除", false))


## 清除全部按关绘画草稿（SaveCoordinator 按 level_path 落 user://drawings/）
func _on_clear_drawings() -> void:
    _confirm("清除全部绘画草稿（不可恢复）？", "清除", func():
        SaveCoordinator.clear_all_drawings()
        _toast("绘画草稿已清除", false))


## 二次确认弹窗（关闭即释放，v3.1：反复确认不再累积隐藏节点）。
func _confirm(text: String, ok_text: String, on_ok: Callable) -> void:
    var dlg := ConfirmationDialog.new()
    dlg.dialog_text = text
    dlg.ok_button_text = ok_text
    dlg.cancel_button_text = "取消"
    # 按钮套统一样式（2026-09-25）：引擎默认主题与项目深色风格不符；顺带补上标题
    # （此前用引擎默认英文标题 "Alert!"，整个界面的唯一英文残留）。
    dlg.title = "请确认"
    if dlg.get_ok_button() != null:
        UiTheme.style_button(dlg.get_ok_button())
    if dlg.get_cancel_button() != null:
        UiTheme.style_button(dlg.get_cancel_button())
    dlg.confirmed.connect(on_ok)
    dlg.visibility_changed.connect(func():
        if not dlg.visible:
            dlg.queue_free())
    add_child(dlg)
    dlg.popup_centered()


## toast 统一走 UiToast（原先本页与 mod_select / skin_browser / main_menu
## 各实现了一份同构的 Label+Timer，行为与配色已经开始分叉）。
func _toast(msg: String, danger: bool = true) -> void:
    UiToast.popup(self, msg, danger)


# ============================ 行构造工具 ============================

## 开关行：HBox = Label + CheckButton；初值由调用方传入（= SettingsManager 当前值）。
func _add_check_row(parent: Node, label: String, setter: Callable, initial: bool) -> CheckButton:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 24)
    _add_label(row, label)
    var chk := CheckButton.new()
    chk.button_pressed = initial
    chk.toggled.connect(setter)
    row.add_child(chk)
    parent.add_child(row)
    return chk


## 选项行：HBox = Label + OptionButton；返回 OptionButton 供调用方加项 / 接信号。
func _add_opt_row(parent: Node, label: String) -> OptionButton:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 24)
    _add_label(row, label)
    var opt := OptionButton.new()
    row.add_child(opt)
    parent.add_child(row)
    return opt


## 按钮行：HBox = Label + Button（用于「清除…」这类带二次确认的操作）。
func _add_button_row(parent: Node, label: String, btn_text: String, on_press: Callable) -> void:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 24)
    _add_label(row, label)
    var btn := Button.new()
    btn.text = btn_text
    btn.focus_mode = Control.FOCUS_NONE
    btn.custom_minimum_size = Vector2(140, 32)
    btn.pressed.connect(on_press)
    row.add_child(btn)
    parent.add_child(row)


func _add_label(parent: Node, text: String) -> void:
    var lb := Label.new()
    lb.text = text
    lb.custom_minimum_size = Vector2(200, 32)
    lb.add_theme_font_size_override("font_size", 18)
    # 垂直居中（2026-09-29）：custom_minimum_size.y = 32 比 18px 字的行高（27）高 5px，
    # 而 Label 的 vertical_alignment 默认是 TOP ⇒ 文字被顶在框顶，和同排 32px 高的
    # 开关 / 下拉 / 滑条的中心错开 2.5px。字号或 ui_scale 一变，这个偏差同步放大。
    lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    # 打标记：供 _align_label_column 收集「行标签」（小节标题走 _add_section_label，不打标记）
    lb.set_meta("_row_label", true)
    parent.add_child(lb)


## 把一页里所有「行标签」的宽度统一到该页最宽的那条（2026-09-29）。
##
## 为什么必须**量**而不能写死：原实现给死 200，而最长的一条是
## 「右键可标问号（标雷 → ？ → 取消）」（18px 下 291px）⇒ 它把那行的开关顶到 291+24 处，
## 同页其它行的开关留在 224 处，一列控件左右参差。写死值还会随字号 / ui_scale /
## 文案长度再次失配，所以改成运行时量一遍。
##
## 只改宽、不改高：Label 的 horizontal_alignment 是 LEFT（默认），加宽只会让**右侧空白**变多，
## 文字位置一个像素都不动 —— 那点空白本来就是这个列宽存在的意义（对齐右侧控件）。
func _align_label_column(scope: Node) -> void:
    var labels: Array[Label] = []
    _gather_row_labels(scope, labels)
    if labels.size() < 2:
        return
    var widest := 0.0
    for lb in labels:
        var f: Font = lb.get_theme_font("font")
        if f == null:
            continue
        widest = maxf(widest, f.get_string_size(lb.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
            lb.get_theme_font_size("font_size")).x)
    if widest <= 0.0:
        return
    # 向上取整到 4px：避免不同字号算出 290.5 这类值让整列宽度随平台字体微调而抖
    var w: float = ceilf(widest / 4.0) * 4.0
    for lb in labels:
        lb.custom_minimum_size = Vector2(w, lb.custom_minimum_size.y)


func _gather_row_labels(root: Node, out: Array[Label]) -> void:
    for c in root.get_children():
        if c is Label and (c as Label).has_meta("_row_label"):
            out.append(c as Label)
        _gather_row_labels(c, out)


## 小节标题：次级色 + 略小字号；带 meta 以便 _apply_theme 在换主题时仍用次级色。
func _add_section_label(parent: Node, text: String) -> Label:
    var lb := Label.new()
    lb.text = text
    lb.add_theme_font_size_override("font_size", 15)
    lb.set_meta("_secondary_label", true)
    parent.add_child(lb)
    return lb


## 取与当前 ui_scale 最接近的档位下标（持久化值可能被手改成中间值）。
func _closest_scale_index(value: float) -> int:
    var best := 0
    var best_d := absf(UI_SCALES[0] - value)
    for i in range(1, UI_SCALES.size()):
        var d: float = absf(UI_SCALES[i] - value)
        if d < best_d:
            best_d = d
            best = i
    return best


# ============================ 主题刷新 ============================

## 递归给整棵子树上色。
## 原实现按 CenterContainer→PanelContainer→TabContainer→VBoxContainer→row 硬编码层级遍历，
## 新增页签 / 分组后必然漏刷（且静态检查与单元测试都发现不了，只有肉眼可见）。
## 改递归后新增层级自动覆盖；皮肤页除外（它自带 _apply_card_styles，覆盖会冲掉「使用中」角标色）。
func _apply_theme() -> void:
    if _panel != null:
        var sb := StyleBoxFlat.new()
        sb.bg_color = ThemeManager.card()
        sb.set_corner_radius_all(10)
        _panel.add_theme_stylebox_override("panel", sb)
    if _tabs != null:
        _style_tabs()
    for n in _collect_controls(self):
        if n is Label:
            n.add_theme_color_override("font_color",
                ThemeManager.text_secondary() if n.has_meta("_secondary_label") else ThemeManager.text())
        elif n is Button:
            _style_button(n)
    queue_redraw()


## 刷 TabContainer 的**内容区底板 + 页签条**。
##
## 为什么必须单独刷（而不是靠 _apply_theme 的递归）：TabContainer 自带一块
## **不透明的** `panel` 样式盒铺在内容区底下，而递归上色只认 Label / Button ⇒
## 它一直吃的是 Godot 引擎默认值（StyleBoxFlat，bg_color ≈ Color(0.1,0.1,0.1,0.6)）。
## 后果：五套浅色 CozyStyle 主题上，那块近黑底把 `text()` 的正文压成**实测 1.67:1**
## （#444d5b 压 #607174；口径见 _pv/probe_skin_contrast.py）——整页设置项几乎读不出来。
##
## 这个缺陷最阴的地方是「不像 bug、像设计」：玩家会以为"设置面板本来就该是深色卡片"，
## 而静态检查、单元测试、乃至截图肉眼扫一遍都可能放过。
##
## 修法：内容区刷成与外层 _panel 同一张底（card）⇒ 正文立刻回到 7.32:1；
## 页签条的选中/未选中/悬停三态与字色也一并接管 —— 否则页签条仍靠引擎默认，
## 在浅色底上同样发灰（选中态尤其看不出选的是哪个）。
func _style_tabs() -> void:
    var card := ThemeManager.card()
    var body := StyleBoxFlat.new()
    body.bg_color = card
    # 与外层 _panel 同为 10：两层同色同圆角，叠在一起看不出接缝
    body.set_corner_radius_all(10)
    _tabs.add_theme_stylebox_override("panel", body)

    _tabs.add_theme_color_override("font_selected_color", ThemeManager.text())
    _tabs.add_theme_color_override("font_unselected_color", ThemeManager.text_secondary())
    _tabs.add_theme_color_override("font_hovered_color", ThemeManager.text())

    # 页签条：未选中 = 页面底色（读作"凹进去的标签槽"），选中 = 内容区同色
    #（读作"这个标签和下面的内容是连着的"）—— 这是标签页最省事的可读性手法。
    var strip := StyleBoxFlat.new()
    strip.bg_color = ThemeManager.bg()
    strip.set_corner_radius_all(8)
    strip.content_margin_left = 12
    strip.content_margin_right = 12
    strip.content_margin_top = 6
    strip.content_margin_bottom = 6
    var sel := strip.duplicate() as StyleBoxFlat
    sel.bg_color = card
    var hov := strip.duplicate() as StyleBoxFlat
    hov.bg_color = card.lightened(0.04)
    _tabs.add_theme_stylebox_override("tab_unselected", strip)
    _tabs.add_theme_stylebox_override("tab_selected", sel)
    _tabs.add_theme_stylebox_override("tab_hovered", hov)


## 递归收集 root 下全部控件；越过 _skin_page 子树（皮肤页自管配色）。
func _collect_controls(root: Node) -> Array:
    var out: Array = []
    for c in root.get_children():
        if c == _skin_page:
            continue
        out.append(c)
        out.append_array(_collect_controls(c))
    return out


func _style_button(btn: Button) -> void:
    UiTheme.style_button(btn)


func _on_theme_changed() -> void:
    _apply_theme()
