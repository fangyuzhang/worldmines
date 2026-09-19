# test_settings_grouping.gd —— 设置界面「信息结构」契约（v3.4 分类重构）
#
# 覆盖（对应交付验收）：
#   ① 每个页签存在且名字正确（画面 / 玩法 / 音效 / 皮肤 / 数据）；
#   ② 每个「应有入口」的设置项都能在界面上按文案找到对应控件，且控件类型正确；
#   ③ 控件初值 == SettingsManager 当前值；
#   ④ 切换控件 → SettingsManager 对应字段变化（抽查含新补入口的项）；
#   ⑤ _apply_theme 递归覆盖到**全部**页签（钉死「硬编码层级遍历 → 新页签漏刷」陷阱）；
#   ⑥ 对局内弹窗只有分组标题，且可调项不比分组前少。
#
# 纪律：SettingsManager 是 autoload（全局单例），用例前后必须恢复现场——写回原值并清理
# user://settings.cfg（与 test_theme_settings / test_reveal_effects 同口径）。
extends GutTest

const CFG := "user://settings.cfg"

## 期望的页签（顺序即展示顺序）
const EXPECTED_TABS := ["画面", "玩法", "音效", "皮肤", "数据"]

## 「应有入口」清单：页签 → 行文案 → 期望控件类型。
## 含任务二要求补入口的全部字段（no_guess/hint_mode/hint_charge/drawing_opacity/ult×3/restart_confirm）。
const EXPECTED_ENTRIES := [
    {"page": "画面", "label": "主题模式", "kind": "OptionButton"},
    {"page": "画面", "label": "全屏模式", "kind": "CheckButton"},
    {"page": "画面", "label": "悬停邻域高亮", "kind": "CheckButton"},
    {"page": "画面", "label": "翻开动效（波浪 / 单格）", "kind": "CheckButton"},
    {"page": "画面", "label": "绘画层透明度", "kind": "HSlider"},
    {"page": "画面", "label": "界面缩放", "kind": "OptionButton"},
    {"page": "玩法", "label": "连携操作（一键展开 / 拖动插旗）", "kind": "CheckButton"},
    {"page": "玩法", "label": "自动存档", "kind": "CheckButton"},
    {"page": "玩法", "label": "键盘操作", "kind": "CheckButton"},
    {"page": "玩法", "label": "重开前确认", "kind": "CheckButton"},
    {"page": "玩法", "label": "无猜模式", "kind": "OptionButton"},
    {"page": "玩法", "label": "提示模式", "kind": "OptionButton"},
    {"page": "玩法", "label": "提示充能（120 秒）", "kind": "CheckButton"},
    {"page": "玩法", "label": "终极：隐藏剩余雷数", "kind": "CheckButton"},
    {"page": "玩法", "label": "终极：隐藏可断定格数", "kind": "CheckButton"},
    {"page": "玩法", "label": "终极：卡住时自动揭星", "kind": "CheckButton"},
    {"page": "音效", "label": "音效", "kind": "CheckButton"},
    {"page": "数据", "label": "绘画草稿存入存档", "kind": "CheckButton"},
    {"page": "数据", "label": "通关进度", "kind": "Button"},
    {"page": "数据", "label": "绘画草稿", "kind": "Button"},
]

# 现场快照
var _saved: Dictionary = {}


func before_each() -> void:
    _rm(CFG)
    _saved = {
        "theme_mode": SettingsManager.theme_mode,
        "ripple_enabled": SettingsManager.ripple_enabled,
        "no_guess_mode": SettingsManager.no_guess_mode,
        "hint_mode": SettingsManager.hint_mode,
        "hint_charge": SettingsManager.hint_charge,
        "restart_confirm": SettingsManager.restart_confirm,
        "ui_scale": SettingsManager.ui_scale,
        "drawing_opacity": SettingsManager.drawing_opacity,
    }


func after_each() -> void:
    SettingsManager.theme_mode = _saved["theme_mode"]
    SettingsManager.ripple_enabled = _saved["ripple_enabled"]
    SettingsManager.no_guess_mode = _saved["no_guess_mode"]
    SettingsManager.hint_mode = _saved["hint_mode"]
    SettingsManager.hint_charge = _saved["hint_charge"]
    SettingsManager.restart_confirm = _saved["restart_confirm"]
    SettingsManager.ui_scale = _saved["ui_scale"]
    SettingsManager.drawing_opacity = _saved["drawing_opacity"]
    _rm(CFG)


func _rm(path: String) -> void:
    if FileAccess.file_exists(path):
        DirAccess.remove_absolute(path)


func _make_panel() -> Control:
    var panel: Control = load("res://ui/settings_panel.tscn").instantiate()
    add_child_autofree(panel)
    return panel


func _all_controls(root: Node) -> Array:
    var out: Array = []
    for c in root.get_children():
        out.append(c)
        out.append_array(_all_controls(c))
    return out


func _find_first(node: Node, type_name: String) -> Node:
    if node.get_class() == type_name:
        return node
    for c in node.get_children():
        var r := _find_first(c, type_name)
        if r != null:
            return r
    return null


func _tabs(panel: Control) -> TabContainer:
    return _find_first(panel, "TabContainer") as TabContainer


func _page(tabs: TabContainer, page_name: String) -> Node:
    for c in tabs.get_children():
        if c.name == page_name:
            return c
    return null


## 在某页里按行文案找控件（_add_check_row / _add_opt_row / _add_button_row 结构：HBox = Label + 控件）。
func _row_control(page: Node, label_text: String) -> Node:
    for c in _all_controls(page):
        if not (c is HBoxContainer):
            continue
        var matched := false
        var ctl: Node = null
        for ch in c.get_children():
            if ch is Label and (ch as Label).text == label_text:
                matched = true
            elif ch is CheckButton or ch is OptionButton or ch is HSlider or ch is Button:
                ctl = ch
        if matched:
            return ctl
    return null


func _kind_of(node: Node) -> String:
    if node is CheckButton:
        return "CheckButton"
    if node is OptionButton:
        return "OptionButton"
    if node is HSlider:
        return "HSlider"
    if node is Button:
        return "Button"
    return "?"


# ---------- ① 页签存在且命名正确 ----------

func test_tabs_exist_and_named() -> void:
    var panel := _make_panel()
    var tabs := _tabs(panel)
    assert_not_null(tabs, "设置面板应有 TabContainer")
    var names: Array = []
    for c in tabs.get_children():
        names.append(String(c.name))  # 节点名是 StringName，转 String 才能与期望值相等比较
    assert_eq(names, EXPECTED_TABS, "页签应为 画面/玩法/音效/皮肤/数据（顺序固定）")


# ---------- ② 每个应有入口的设置项都能找到控件 ----------

func test_every_expected_entry_has_control() -> void:
    var panel := _make_panel()
    var tabs := _tabs(panel)
    for e in EXPECTED_ENTRIES:
        var page: Node = _page(tabs, e["page"])
        assert_not_null(page, "页签「%s」应存在" % e["page"])
        var ctl: Node = _row_control(page, e["label"])
        assert_not_null(ctl, "「%s」页里应能找到设置项「%s」的控件" % [e["page"], e["label"]])
        if ctl != null:
            assert_eq(_kind_of(ctl), e["kind"], "「%s」的控件类型应为 %s" % [e["label"], e["kind"]])


# ---------- ③ 控件初值 == SettingsManager 当前值 ----------

func test_initial_values_match_manager() -> void:
    # 人为设一组非默认值（直接赋内存值，不写盘），验证面板读取的是当前值
    SettingsManager.no_guess_mode = 1
    SettingsManager.hint_mode = 2
    SettingsManager.restart_confirm = false
    SettingsManager.ui_scale = 1.25
    SettingsManager.drawing_opacity = 0.7
    SettingsManager.ripple_enabled = false

    var panel := _make_panel()
    assert_eq(panel._no_guess_opt.selected, 1, "无猜模式初值应 = 当前值")
    assert_eq(panel._hint_mode_opt.selected, 2, "提示模式初值应 = 当前值")
    assert_eq(panel._restart_confirm_chk.button_pressed, false, "重开前确认初值应 = 当前值")
    assert_eq(panel._ui_scale_opt.selected, 1, "界面缩放初值应落在 125% 档")
    assert_almost_eq(panel._opacity_slider.value, 0.7, 0.001, "绘画层透明度初值应 = 当前值")
    assert_eq(panel._ripple_chk.button_pressed, false, "翻开动效初值应 = 当前值")
    assert_eq(panel._theme_opt.selected, ["system", "dark", "light"].find(SettingsManager.theme_mode),
        "主题模式初值应 = 当前值")


# ---------- ④ 切换控件 → SettingsManager 字段变化 ----------

func test_toggle_no_guess_updates_manager() -> void:
    var panel := _make_panel()
    panel._no_guess_opt.item_selected.emit(1)   # 模拟用户选「专家」
    assert_eq(SettingsManager.no_guess_mode, 1, "切换无猜模式应立即生效")
    panel._no_guess_opt.item_selected.emit(0)
    assert_eq(SettingsManager.no_guess_mode, 0, "切回关闭应立即生效")


func test_toggle_hint_mode_updates_manager() -> void:
    var panel := _make_panel()
    panel._hint_mode_opt.item_selected.emit(2)  # 禁用提示
    assert_eq(SettingsManager.hint_mode, 2, "切换提示模式应立即生效")


func test_toggle_restart_confirm_updates_manager() -> void:
    var panel := _make_panel()
    var before: bool = SettingsManager.restart_confirm
    panel._restart_confirm_chk.button_pressed = not before
    assert_eq(SettingsManager.restart_confirm, not before, "切换重开前确认应立即生效")


func test_toggle_ui_scale_updates_manager() -> void:
    var panel := _make_panel()
    panel._ui_scale_opt.item_selected.emit(2)   # 150%
    assert_almost_eq(SettingsManager.ui_scale, 1.5, 0.001, "切换界面缩放应立即生效")
    assert_true(FileAccess.file_exists(CFG), "界面缩放应落盘")


# ---------- ⑤ _apply_theme 递归覆盖到全部页签 ----------

func test_theme_covers_all_new_tabs() -> void:
    var panel := _make_panel()
    var tabs := _tabs(panel)
    for page_name in ["画面", "玩法", "音效", "数据"]:
        var page: Node = _page(tabs, page_name)
        var labels: Array = []
        for c in _all_controls(page):
            if c is Label:
                labels.append(c)
        assert_true(labels.size() > 0, "「%s」页应有 Label" % page_name)
        for lb in labels:
            assert_true(lb.has_theme_color_override("font_color"),
                "「%s」页的 Label「%s」应被 _apply_theme 覆盖字体色（硬编码层级遍历会漏刷）"
                % [page_name, (lb as Label).text])
            var expected: Color = ThemeManager.text_secondary() if lb.has_meta("_secondary_label") else ThemeManager.text()
            assert_eq(lb.get_theme_color("font_color"), expected,
                "「%s」页 Label「%s」的字体色应为主题色" % [page_name, (lb as Label).text])


# ---------- ⑥ 对局内弹窗：分组标题 + 可调项不减少 ----------

func test_popup_has_groups_and_not_fewer_controls() -> void:
    var popup: PopupPanel = load("res://ui/settings_popup.tscn").instantiate()
    add_child_autofree(popup)
    # 分组标题存在
    var texts: Array = []
    for c in _all_controls(popup):
        if c is Label:
            texts.append((c as Label).text)
    for g in ["外观", "操作", "对局与提示", "其他"]:
        assert_true(texts.has(g), "弹窗应有分组标题「%s」" % g)
    # 可调项数量不比分组前少（分组前为 14：3 OptionButton + 10 CheckButton + 1 HSlider）
    var n := 0
    for c in _all_controls(popup):
        if c is CheckButton or c is OptionButton or c is HSlider:
            n += 1
    assert_true(n >= 14, "弹窗可调项不得少于分组前的 14 个，实际 %d" % n)


func test_popup_group_labels_are_themed() -> void:
    var popup: PopupPanel = load("res://ui/settings_popup.tscn").instantiate()
    add_child_autofree(popup)
    for c in _all_controls(popup):
        if c is Label:
            assert_true(c.has_theme_color_override("font_color"),
                "弹窗 Label「%s」应被 _apply_theme 覆盖字体色" % (c as Label).text)
