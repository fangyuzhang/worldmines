# codex.gd —— 规则图鉴页（变体/约束规则说明 + 操作说明）
# 名称与难度取自 VariantRegistry（唯一事实源）；规则文字在此维护，与引擎实现一一对应。
# 全部色值经 ThemeManager；UI 由代码构建（与其余页面一致的 tscn 根 + script 风格）。
extends Control

# 线索型规则说明（8 个：经典 + 7 变体线索）
const CLUE_DESC := {
    "classic": "数字 = 周围 8 格（含对角）中的雷数，范围 0~8。",
    "4n": "数字 = 上、下、左、右 4 个正交邻格中的雷数，不含对角，范围 0~4。",
    "clock": "从正上方开始顺时针把 8 个邻格编号 1~8，数字 = 顺时针遇到的第一颗雷的编号；周围无雷显示 0。",
    "hv": "显示两个数字 [正交雷数, 对角雷数]：前者只数上下左右，后者只数四个斜角，各 0~4。",
    "fr": "数字 = 从本格向右遇到的第一颗雷之前的安全格数量；右侧一路无雷显示 ∞。",
    "loopruns": "把 8 个邻格按环形顺序（首尾相接）排列，数字 = 其中连续成段的雷的段数，范围 0~4。",
    "distsum": "曼哈顿加权和：正交邻格每颗雷记 1 分、对角邻格每颗雷记 2 分，数字为总分，范围 0~12。",
    "sc": "数字 = 4 个对角邻格中「与本格同色」（行号+列号 奇偶相同）的雷数，范围 0~4。",
}

# 全局约束（布局型）规则说明（7 个）
const CONSTRAINT_DESC := {
    "mx": "雷的分布左右镜像对称：左半边某格有雷，其镜像位置也必有雷。",
    "rl": "任意相邻两行的雷数之差恰好等于 1。",
    "pf": "任意 2×2 的窗口内，雷的数量不超过 2。",
    "qd": "去掉正中央的行与列后，左上/右上/左下/右下四个象限的雷数彼此相等。",
    "dt": "棋盘被预置骨牌（相邻两格一组）划分，每一组骨牌中恰好有 1 颗雷。",
    "ep": "最左一列与最右一列的雷数相等。",
    "4c": "按棋盘格黑白染色后，黑格与白格上的雷数相等。",
}

# 童趣化（GDD 26 号「方块格子岛」）：15 个小精灵的名字 + 大白话台词。
# 台词口径以 26 号文档 §8「一句话教学」为准，与引擎规则语义一一对应。
const SPRITES := {
    "classic": "八方", "4n": "四方", "clock": "圈圈", "hv": "横竖",
    "fr": "望望", "loopruns": "堆堆", "distsum": "沉沉", "sc": "亲亲",
    "mx": "同同", "rl": "步步", "pf": "不行", "qd": "分分",
    "dt": "双双", "ep": "平平", "4c": "花花",
}
const SPRITE_LINES := {
    "classic": "上下左右加四个斜角，一共八方，藏几只我写几！",
    "4n": "我只数上下左右，斜角的我不管～",
    "clock": "从头顶开始顺时针数，第一只藏在几点钟方向？",
    "hv": "我分两句说：横的几只，竖的几只。",
    "fr": "我脖子只能朝右，右边第一只离我几步？",
    "loopruns": "别数几只，数它们抱成了几堆！",
    "distsum": "离我越远越压秤，把重量加起来是几？",
    "sc": "我只数和我一样颜色的小伙伴哦！",
    "mx": "我左右是一模一样的，看清左边，右边就知道啦！",
    "rl": "每一排只比上一排多一只或少一只，像不像下台阶？",
    "pf": "记住哦，这几种摆法是不允许出现的！",
    "qd": "地分四块，每块藏几只我都写好了，看小黑板！",
    "dt": "两块是一对，一对里最多藏一只，找到一只另一只就安全！",
    "ep": "最左边和最右边一样多，天平不许歪！",
    "4c": "黑格白格分开数，各有几只，心里有数！",
}

const _COMBO_LINES := [
    "布局 + 线索（如 mx+4n）：全局约束与线索规则同时生效。",
    "双布局（如 mx+rl）：两个全局约束同时生效，线索采用经典规则。",
    "线索混合（如 4n+sc）：同一格同时给出两个线索值，格内分两行显示。",
]
const _BASIC_LINES := [
    "目标：翻开所有非雷格即胜利；点到雷即失败。",
    "左键翻开；右键循环：无标记 → 旗 → ? → 无标记。",
    "键盘：WASD / 方向键移动，空格或回车翻开，F 插旗，H 提示，R 重开（需在设置中开启「键盘操作」）。",
    "提示（HUD「提示」按钮或 H 键）：给出当前一步的必然推理，绿框 = 必安全、红框 = 必是雷；只推 100% 确定的一步。",
    "? 格：部分关卡的 ? 格只给出数字区间，翻开后显示区间内的一个候选值。",
]

var _title_label: Label


func _ready() -> void:
    add_to_group("themed")
    ThemeManager.theme_changed.connect(_on_theme_changed)
    _build_ui()
    _apply_theme()


func _build_ui() -> void:
    var scroll := ScrollContainer.new()
    scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    scroll.offset_top = 16
    scroll.offset_bottom = -72
    scroll.offset_left = 24
    scroll.offset_right = -24
    add_child(scroll)

    var vbox := VBoxContainer.new()
    vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vbox.add_theme_constant_override("separation", 10)
    scroll.add_child(vbox)

    _title_label = _section(vbox, "规则图鉴")

    _lines(vbox, _BASIC_LINES)
    _section(vbox, "一、线索型（数字的含义）")
    for code in ["classic", "4n", "clock", "hv", "fr", "loopruns", "distsum", "sc"]:
        _def_entry(vbox, code, "clue")
    _section(vbox, "二、布局型（全局约束）")
    for code in VariantRegistry.GLOBAL_CONSTRAINTS:
        _def_entry(vbox, code, "constraint")
    _section(vbox, "三、组合规则")
    _lines(vbox, _COMBO_LINES)

    # 返回按钮：统一右上角（独立定位，从底部移到右上）
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


func _section(parent: Node, text: String) -> Label:
    var lb := Label.new()
    lb.text = text
    lb.add_theme_font_size_override("font_size", 26 if text == "规则图鉴" else 20)
    lb.custom_minimum_size = Vector2(0, 36)
    parent.add_child(lb)
    return lb


func _lines(parent: Node, lines: Array) -> void:
    for t in lines:
        var lb := Label.new()
        lb.text = "· " + str(t)
        lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        lb.add_theme_font_size_override("font_size", 16)
        parent.add_child(lb)


## 依据 VariantRegistry.definitions() 取名/难度，规则文字取本文件常量。
func _def_entry(parent: Node, code: String, kind: String) -> void:
    var defs := VariantRegistry.definitions()
    if not defs.has(code):
        return
    var d: Dictionary = defs[code]
    var desc: String = (CLUE_DESC if kind == "clue" else CONSTRAINT_DESC).get(code, "")
    var text := "%s（%s）%s：%s" % [str(d["name"]), code, str(d["diff"]), desc]
    if SPRITES.has(code):
        text += "\n　 小精灵「%s」：%s" % [SPRITES[code], SPRITE_LINES[code]]
    var lb := Label.new()
    lb.text = text
    lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    lb.add_theme_font_size_override("font_size", 16)
    parent.add_child(lb)


# ============ 主题 ============

func _apply_theme() -> void:
    if _title_label != null:
        _title_label.add_theme_color_override("font_color", ThemeManager.text())
    for n in _all_labels(self):
        if n == _title_label:
            continue
        n.add_theme_color_override("font_color", ThemeManager.text_secondary())
    for n in get_children():
        if n is Button:
            _style_button(n)
    queue_redraw()


func _all_labels(root: Node) -> Array:
    var out: Array = []
    for c in root.get_children():
        if c is Label:
            out.append(c)
        out.append_array(_all_labels(c))
    return out


func _style_button(btn: Button) -> void:
    UiTheme.style_button(btn)


func _on_theme_changed() -> void:
    _apply_theme()
