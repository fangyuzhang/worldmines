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
var _restart_confirm_chk: CheckButton
var _no_guess_opt: OptionButton
var _hint_mode_opt: OptionButton
var _hint_charge_chk: CheckButton
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
const THEME_MODES := ["system", "dark", "light"]


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

    _panel = PanelContainer.new()
    center.add_child(_panel)

    var tabs := TabContainer.new()
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
    _build_audio_page(audio_page.get_child(0) as VBoxContainer)
    _build_data_page(data_page.get_child(0) as VBoxContainer)

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
    # 主题模式（跟随系统 / 深色 / 亮色）
    var theme_row := HBoxContainer.new()
    theme_row.add_theme_constant_override("separation", 24)
    _add_label(theme_row, "主题模式")
    _theme_opt = OptionButton.new()
    _theme_opt.add_item("跟随系统")
    _theme_opt.add_item("深色")
    _theme_opt.add_item("亮色")
    _theme_opt.item_selected.connect(func(idx: int):
        SettingsManager.set_theme_mode(THEME_MODES[idx]))
    _theme_opt.selected = THEME_MODES.find(SettingsManager.theme_mode)
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
    _restart_confirm_chk = _add_check_row(page, "重开前确认",
        func(v: bool): SettingsManager.set_restart_confirm(v), SettingsManager.restart_confirm)

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

    _hint_charge_chk = _add_check_row(page, "提示充能（120 秒）",
        func(v: bool): SettingsManager.set_hint_charge(v), SettingsManager.hint_charge)

    # 终极模式三项：只在「无猜模式 = 终极」的关卡里起作用 —— 必须标注，否则玩家会困惑
    _add_section_label(page, "终极模式附加开关（仅「无猜模式 = 终极」时生效）")
    _ult_hide_mines_chk = _add_check_row(page, "终极：隐藏剩余雷数",
        func(v: bool): SettingsManager.set_ult_hide_mines(v), SettingsManager.ult_hide_mines)
    _ult_hide_deducible_chk = _add_check_row(page, "终极：隐藏可断定格数",
        func(v: bool): SettingsManager.set_ult_hide_deducible(v), SettingsManager.ult_hide_deducible)
    _ult_auto_reveal_chk = _add_check_row(page, "终极：卡住时自动揭星",
        func(v: bool): SettingsManager.set_ult_auto_reveal(v), SettingsManager.ult_auto_reveal)


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
    parent.add_child(lb)


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
    for n in _collect_controls(self):
        if n is Label:
            n.add_theme_color_override("font_color",
                ThemeManager.text_secondary() if n.has_meta("_secondary_label") else ThemeManager.text())
        elif n is Button:
            _style_button(n)
    queue_redraw()


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
