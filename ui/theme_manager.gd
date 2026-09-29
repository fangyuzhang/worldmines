# theme_manager.gd —— 取色中枢（全工程唯一合法色源）【plan1.1 §10.7.1】
# 色板照抄 plan1.1 §8.4.1~8.4.4，任何其他文件禁止出现硬编码 RGB。
# 主题切换：300ms Tween 逐色 lerp，每步广播 theme_changed，不中断对局。
#
# 【2026-09-29】新增 **CozyStyle 五主题家族**（海盐/陶土/鼠尾草/暮紫/雾霭，见文件下方 _COZY）。
#   旧的 dark/light 与 _DARK/_LIGHT/_NUM_*/_OVERLAY_* **一字未改**：test_theme_settings.gd 对
#   dark/light 的若干 hex 做了逐字断言，覆写它们会让契约当场变红、也会让老玩家的存档主题
#   失去还原。新家族是**追加**的第 2 套体系，默认主题（"system" 的落点）指向它。
extends Node
## autoload 名：ThemeManager

signal theme_changed
## 【09-28 审计修复 R4】「一次切换**收口**」信号：`theme_changed` 在 300ms 过渡里每步都发（~10 次），
## 便宜的消费者（改个色、`queue_redraw`）跟它走没问题；但**重建页面 / 重跑 CP-SAT 查询**这类昂贵消费者
## 若也跟 `theme_changed`，一次切换就会白跑十遍（先前 `level_select` 只能自己塞 300ms 去抖）。
## `theme_settled` 只在过渡**末步**发一次；又因为 `_retarget()` 会 kill 掉上一个 tween
##（被 kill 的 tween 不再触发回调），连点/连切时**天然只发最后一次** ⇒ 无需超时去抖、也不会漏发。
signal theme_settled

## 实际生效的主题 id：内置 "dark" | "light"，或 CozyStyle 家族的 COZY_IDS 之一。
## （旧注释写"只有 dark|light"，2026-09-29 起不再成立。）
var mode: String = "cozy_salt"

var _active := {}  # 当前生效色板（插值期间为即时值）
var _target := {}  # 目标色板
var _tween: Tween
var _default_theme: Theme  # 全局兜底文本色（挂到根 Window，见 _apply_default_theme）

# Mod 皮肤覆盖（皮肤系统核心）：skin_id="" 表示内置主题；
# _skin_colors 覆盖色板键值，_skin_numbers 覆盖数字 1~8 配色。
var skin_id: String = ""
var _skin_colors := {}
var _skin_numbers: Array = []

# §8.4.1 护眼深色模式（默认）
const _DARK := {
    "bg": Color("#1E1E24"),
    "card": Color("#28282E"),
    "cell_hidden": Color("#3A3A42"),
    "cell_revealed": Color("#232328"),
    "text": Color("#E0E0E6"),
    "text_secondary": Color("#888892"),
    "accent": Color("#7CB9E8"),
    "danger": Color("#C0504D"),
    "safe": Color("#4EA96B"),
    "grid_line": Color(0, 0, 0, 0.20),
}

# §8.4.2 护眼亮色模式
const _LIGHT := {
    "bg": Color("#F4F4F0"),
    "card": Color("#FFFFFF"),
    "cell_hidden": Color("#D6D6CE"),
    "cell_revealed": Color("#EBEBE4"),
    "text": Color("#333333"),
    "text_secondary": Color("#888888"),
    "accent": Color("#2D7BB0"),
    "danger": Color("#B71C1C"),
    "safe": Color("#1E7A34"),
    "grid_line": Color(0, 0, 0, 0.10),
}

# §8.4.3 线索数字 1~8 配色（双主题）
const _NUM_DARK := [
    Color("#5FA8E8"), Color("#79C07D"), Color("#E66666"), Color("#8E9DF0"),
    Color("#C98A5B"), Color("#5BC8C8"), Color("#E0E0E6"), Color("#9494A0"),
]
const _NUM_LIGHT := [
    Color("#1A56C4"), Color("#1E7A34"), Color("#C0392B"), Color("#1F3A93"),
    Color("#8B5A2B"), Color("#0E8388"), Color("#1A1A1A"), Color("#737373"),
]

# §8.4.4 悬停遮罩 / 终局遮罩 / 雷体色
const _OVERLAY_DARK := {
    "hover_center": Color(1, 1, 1, 0.25),
    "hover_neighbor": Color(0.48, 0.72, 0.91, 0.16),
    "endgame_dim": Color(0, 0, 0, 0.55),
    "mine_body": Color("#D8D8DC"),
}
const _OVERLAY_LIGHT := {
    "hover_center": Color(0, 0, 0, 0.18),
    "hover_neighbor": Color(0, 0, 0, 0.12),
    "endgame_dim": Color(0, 0, 0, 0.35),
    "mine_body": Color("#222226"),
}


# ============ CozyStyle 五主题家族（2026-09-29 接入）============
#
# 来源：CozySudoku 逆向出的 50 角色色板（output/CozyStyle_Reusable_Assets/[04]_palettes/
#       palette_new_5themes.json），按「保留色相/饱和度、只对受门禁约束的角色数值求解明度」
#       的规则映射到本工程的色板键。逐键的推导方式与实测对比度见
#       _pv/cozy_derive_report.txt（3 条工程硬断言 + 16 条配对护栏，5 套主题全部通过）。
#
# ⚠️ 与既有 _DARK/_LIGHT 的关系：**纯追加**，一字未改。原因是 test_theme_settings.gd
#    对 dark/light 的若干 hex 做了逐字断言（#1E1E24 / #3A3A42 / #C0504D / #5FA8E8…），
#    直接覆写旧色板会让那些契约当场变红，也会让老玩家的存档主题失去还原。
#
# CozyStyle 是**粉彩低对比**体系（实测多数角色对 GlobalBg 只有 1.0~2.7:1），照字面搬会
# 直接违反本工程的三条 WCAG 硬断言，故受约束角色（text / danger_text / board_grid /
# accent / safe / mine_body）的**明度是求解出来的**，色相与饱和度才是 CozyStyle 原值。

## 全部主题 id（顺序即设置页下拉与皮肤浏览器的展示顺序；前两项恒为跟随系统/旧内置）
const THEME_IDS: Array = ["system", "dark", "light",
    "cozy_salt", "cozy_terracotta", "cozy_sage", "cozy_dusk", "cozy_haze"]
## CozyStyle 家族（需要「是否新体系」判定的地方用这个）
const COZY_IDS: Array = ["cozy_salt", "cozy_terracotta", "cozy_sage", "cozy_dusk", "cozy_haze"]
## 默认主题（SettingsManager.theme_mode == "system" 时落到这里）
const DEFAULT_COZY: String = "cozy_salt"

## id → 中文名（设置页 / 皮肤浏览器共用；避免两处各写一份显示名）
const THEME_LABELS := {
    "system": "跟随系统",
    "dark": "深色（旧）",
    "light": "亮色（旧）",
    "cozy_salt": "海盐",
    "cozy_terracotta": "陶土",
    "cozy_sage": "鼠尾草",
    "cozy_dusk": "暮紫",
    "cozy_haze": "雾霭",
}

## CozyStyle 五套色板。在 _DARK/_LIGHT 的 14 键（10 主色 + 4 遮罩）之上，
## 本体系另有 4 个键：3 个**配对字色**（accent_text / danger_text / safe_text）+
## 1 个**棋盘垫子**（board_mat，CozyStyle 的 BoardBg 角色）——
## CozyStyle 本身就是「配对色」体系（每个底色都有专属字色），原工程把 text() 当
## accent 底上的字色，在浅色下本来就只有 ~2:1，补齐配对是这次改造的顺带修复。
const _COZY := {
    "cozy_salt": {
        "bg": Color("#b7c9d4"),
        "card": Color("#cbf5fc"),
        "cell_hidden": Color("#ccdee6"),
        "cell_revealed": Color("#b7c9d4"),
        "text": Color("#444d5b"),
        "text_secondary": Color("#5b6471"),
        "accent": Color("#3471a1"),
        "accent_text": Color("#edfafd"),
        "danger": Color("#c92a16"),
        "danger_text": Color("#992719"),
        "safe": Color("#1f5c40"),
        "grid_line": Color(0.443137, 0.52549, 0.65098, 0.34),
        "board_grid": Color(0.156863, 0.192157, 0.25098, 0.62),
        "board_mat": Color("#526685"),
        "hover_center": Color(1.0, 1.0, 1.0, 0.34),
        "hover_neighbor": Color(0.203922, 0.443137, 0.631373, 0.16),
        "endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
        "mine_body": Color("#4e535b"),
        "pet_fur": Color("#7b889d"),
        "pet_fur_2": Color("#64748d"),
        "pet_patch": Color("#a9aeb5"),
        "pet_ink": Color("#353d4a"),
        "pet_eye": Color("#dee0e1"),
        "pet_pupil": Color("#596373"),
        "pet_nose": Color("#b04c71"),
        "pet_leaf": Color("#43af7d"),
        "pet_leaf_2": Color("#329d6c"),
        "pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
        # `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
        "safe_text": Color("#1f5c40"),
    },
    "cozy_terracotta": {
        "bg": Color("#d3c1b2"),
        "card": Color("#f9cbba"),
        "cell_hidden": Color("#ebdecd"),
        "cell_revealed": Color("#d3c1b2"),
        "text": Color("#564842"),
        "text_secondary": Color("#665a55"),
        "accent": Color("#9a5b32"),
        "accent_text": Color("#fdf7ec"),
        "danger": Color("#c33016"),
        "danger_text": Color("#932b18"),
        "safe": Color("#1e5a3e"),
        "grid_line": Color(0.631373, 0.494118, 0.466667, 0.34),
        "board_grid": Color(0.25098, 0.184314, 0.172549, 0.62),
        "board_mat": Color("#7d5c56"),
        "hover_center": Color(1.0, 1.0, 1.0, 0.34),
        "hover_neighbor": Color(0.603922, 0.356863, 0.196078, 0.16),
        "endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
        "mine_body": Color("#58504d"),
        "pet_fur": Color("#97807c"),
        "pet_fur_2": Color("#866b66"),
        "pet_patch": Color("#b1aaa8"),
        "pet_ink": Color("#453735"),
        "pet_eye": Color("#dedcdc"),
        "pet_pupil": Color("#6e5d5a"),
        "pet_nose": Color("#ae4a6f"),
        "pet_leaf": Color("#42ad7b"),
        "pet_leaf_2": Color("#319b6a"),
        "pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
        # `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
        "safe_text": Color("#1e5a3e"),
    },
    "cozy_sage": {
        "bg": Color("#bbd4c8"),
        "card": Color("#c3faee"),
        "cell_hidden": Color("#cee4d8"),
        "cell_revealed": Color("#bbd4c8"),
        "text": Color("#445454"),
        "text_secondary": Color("#5c6c6b"),
        "accent": Color("#2e7f67"),
        "accent_text": Color("#ffffff"),
        "danger": Color("#d42c18"),
        "danger_text": Color("#a32a1b"),
        "safe": Color("#216244"),
        "grid_line": Color(0.454902, 0.592157, 0.623529, 0.34),
        "board_grid": Color(0.152941, 0.207843, 0.219608, 0.62),
        "board_mat": Color("#516f77"),
        "hover_center": Color(1.0, 1.0, 1.0, 0.34),
        "hover_neighbor": Color(0.180392, 0.498039, 0.403922, 0.16),
        "endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
        "mine_body": Color("#515a5a"),
        "pet_fur": Color("#7b9197"),
        "pet_fur_2": Color("#637d83"),
        "pet_patch": Color("#aeb6b7"),
        "pet_ink": Color("#364448"),
        "pet_eye": Color("#e7e8e9"),
        "pet_pupil": Color("#5a6a6e"),
        "pet_nose": Color("#ac5e4a"),
        "pet_leaf": Color("#45b782"),
        "pet_leaf_2": Color("#34a471"),
        "pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
        # `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
        "safe_text": Color("#216244"),
    },
    "cozy_dusk": {
        "bg": Color("#c2bad6"),
        "card": Color("#eedffc"),
        "cell_hidden": Color("#d5cfe8"),
        "cell_revealed": Color("#c2bad6"),
        "text": Color("#4d4357"),
        "text_secondary": Color("#645a6d"),
        "accent": Color("#7f4bc2"),
        "accent_text": Color("#fdfaed"),
        "danger": Color("#be2815"),
        "danger_text": Color("#8f2517"),
        "safe": Color("#1d563c"),
        "grid_line": Color(0.592157, 0.458824, 0.658824, 0.34),
        "board_grid": Color(0.215686, 0.152941, 0.25098, 0.62),
        "board_mat": Color("#745385"),
        "hover_center": Color(1.0, 1.0, 1.0, 0.34),
        "hover_neighbor": Color(0.498039, 0.294118, 0.760784, 0.16),
        "endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
        "mine_body": Color("#514b56"),
        "pet_fur": Color("#8f789b"),
        "pet_fur_2": Color("#7e628b"),
        "pet_patch": Color("#aba3af"),
        "pet_ink": Color("#3f3146"),
        "pet_eye": Color("#d7d5d8"),
        "pet_pupil": Color("#685670"),
        "pet_nose": Color("#a6476a"),
        "pet_leaf": Color("#40a778"),
        "pet_leaf_2": Color("#2f9567"),
        "pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
        # `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
        "safe_text": Color("#1d563c"),
    },
    "cozy_haze": {
        "bg": Color("#bdd4d8"),
        "card": Color("#fef3f8"),
        "cell_hidden": Color("#d1e6e6"),
        "cell_revealed": Color("#bdd4d8"),
        "text": Color("#4a545c"),
        "text_secondary": Color("#626b73"),
        "accent": Color("#367b94"),
        "accent_text": Color("#ffffff"),
        "danger": Color("#d52d18"),
        "danger_text": Color("#a52a1b"),
        "safe": Color("#216345"),
        "grid_line": Color(0.454902, 0.529412, 0.643137, 0.34),
        "board_grid": Color(0.168627, 0.203922, 0.262745, 0.62),
        "board_mat": Color("#596d8b"),
        "hover_center": Color(1.0, 1.0, 1.0, 0.34),
        "hover_neighbor": Color(0.211765, 0.482353, 0.580392, 0.16),
        "endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
        "mine_body": Color("#555a5f"),
        "pet_fur": Color("#848fa1"),
        "pet_fur_2": Color("#6a7b92"),
        "pet_patch": Color("#b2b6bb"),
        "pet_ink": Color("#3b4350"),
        "pet_eye": Color("#e9eaea"),
        "pet_pupil": Color("#5f6a79"),
        "pet_nose": Color("#b65477"),
        "pet_leaf": Color("#46b884"),
        "pet_leaf_2": Color("#34a572"),
        "pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
        # `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
        "safe_text": Color("#216345"),
    },
}

## CozyStyle 各主题的线索数字 1~8。色相**不随主题旋转**（「1蓝2绿3红4紫5琥珀6青」
## 是扫雷玩家的跨主题肌肉记忆），主题族性只由饱和度档位携带；7/8 为中性色且显式
## 给定不同明度（否则两者会收敛到肉眼不可分的相邻色）。
const _COZY_NUM := {
    "cozy_salt": [
        Color("#225485"), Color("#1e5c38"), Color("#942e23"), Color("#68399f"), Color("#6f4a1c"),
        Color("#215960"), Color("#373e43"), Color("#4d5257")
    ],
    "cozy_terracotta": [
        Color("#215284"), Color("#1d5b37"), Color("#912d22"), Color("#66389c"), Color("#6d481c"),
        Color("#20575e"), Color("#443c37"), Color("#554f4c")
    ],
    "cozy_sage": [
        Color("#2c5987"), Color("#27623f"), Color("#95392f"), Color("#6c429c"), Color("#735026"),
        Color("#295e64"), Color("#384340"), Color("#505956")
    ],
    "cozy_dusk": [
        Color("#234e7a"), Color("#1e5636"), Color("#872e24"), Color("#61378f"), Color("#67451d"),
        Color("#215359"), Color("#3c3743"), Color("#4e4a54")
    ],
    "cozy_haze": [
        Color("#2d5a88"), Color("#276340"), Color("#963a2f"), Color("#6d439d"), Color("#745127"),
        Color("#2a5f65"), Color("#384043"), Color("#52595c")
    ],
}






func _ready() -> void:
    mode = _settings_mode()
    _target = _palette_for(mode)
    _active = _target.duplicate()
    _apply_clear_color()
    _apply_default_theme()
    if SettingsManager != null:
        SettingsManager.settings_changed.connect(_on_settings)


func _settings_mode() -> String:
    var want := DEFAULT_COZY
    if SettingsManager != null and SettingsManager.theme_mode != null:
        want = SettingsManager.theme_mode
    if THEME_IDS.has(want) and want != "system":
        return want
    # "system"：Godot 4.7 无可靠系统暗色检测接口 → 按文档降级（§8.4.6）。
    # 2026-09-29 起降级目标由「深色」改为 **CozyStyle 默认主题**：粉彩家族成了主视觉，
    # 新装用户第一眼就该看到它，而不是回到旧的护眼深色。
    return DEFAULT_COZY


## id → 显示名（设置页 / 皮肤浏览器共用一份，避免两处各写一份显示名而漂移）。
func theme_label(id: String) -> String:
    return str(THEME_LABELS.get(id, id))


## 是否属于 CozyStyle 家族（需要按「新体系」分支的地方用这个，别散写 begin_with("cozy")）。
func is_cozy(id: String = "") -> bool:
    var m := id if id != "" else mode
    return COZY_IDS.has(m)


func _palette_for(m: String) -> Dictionary:
    # CozyStyle 家族：色板表自带 4 个遮罩键（不像 dark/light 那样与 _OVERLAY_* 分开），
    # 因为五套主题的遮罩强度都是逐主题算出来的，合在一张表里读起来才完整。
    var cozy: bool = _COZY.has(m)
    var base: Dictionary
    if cozy:
        base = (_COZY[m] as Dictionary).duplicate()
    else:
        base = (_DARK if m == "dark" else _LIGHT).duplicate()
        var overlay := _OVERLAY_DARK if m == "dark" else _OVERLAY_LIGHT
        for k in overlay:
            base[k] = overlay[k]
    # 皮肤覆盖：仅覆盖 base 中已有的键，未知键静默忽略（防皮肤包损坏导致崩溃）
    for k in _skin_colors:
        if base.has(k):
            base[k] = _skin_colors[k]
    return base


func _on_settings() -> void:
    var want := _settings_mode()
    if want == mode:
        return
    mode = want
    _retarget()


## 应用皮肤（id 非空则覆盖色板与数字色）；base_mode 同时设定内置底版。
## 切换同样走 300ms 平滑过渡，不中断对局。
func apply_skin(new_id: String, colors: Dictionary, numbers: Array, base_mode: String = "") -> void:
    skin_id = new_id
    _skin_colors = colors
    _skin_numbers = numbers
    if _is_theme_id(base_mode):
        mode = base_mode
    _retarget()


## 清除皮肤，回到内置主题；base_mode 可同时切换内置底版。
func clear_skin(base_mode: String = "") -> void:
    skin_id = ""
    _skin_colors = {}
    _skin_numbers = []
    if _is_theme_id(base_mode):
        mode = base_mode
    _retarget()


## base_mode 是否是一个**可用的具体主题 id**（"system" 与空串不算——它们只是"用默认"的意思）。
func _is_theme_id(v: String) -> bool:
    return v != "" and v != "system" and THEME_IDS.has(v)


func _retarget() -> void:
    _target = _palette_for(mode)
    if _tween != null and _tween.is_valid():
        _tween.kill()
    # 300ms 平滑过渡：逐色 lerp（§8.4.6），期间每步广播 theme_changed
    _tween = create_tween()
    var steps := 9  # ~33ms/步
    var keys := _target.keys()
    for i in range(1, steps + 1):
        var frac := float(i) / float(steps)
        _tween.tween_callback(_lerp_step.bind(keys, frac))
    _tween.tween_callback(_apply_final)


func _lerp_step(keys: Array, frac: float) -> void:
    for k in keys:
        if not _target.has(k):
            continue
        if not _active.has(k):
            # 跨家族切换时键集会变宽（dark/light 14 键 ↔ CozyStyle 17 键，多出
            # accent_text / danger_text / safe_text）。缺键直接取目标值，否则这 300ms 里
            # 取色会落到 getter 的兜底色、过渡末尾再"跳"一下。
            _active[k] = _target[k]
        else:
            _active[k] = (_active[k] as Color).lerp(_target[k], frac)
    _apply_clear_color()   # 底色跟着 300ms 一起渐变，避免"卡片在过渡、底色却已经跳完"
    _apply_default_theme()
    theme_changed.emit()


func _apply_final() -> void:
    _active = _target.duplicate()
    _apply_clear_color()
    _apply_default_theme()
    theme_changed.emit()
    theme_settled.emit()   # R4：末步收口（昂贵重建只跟这一拍）


## 页面底色接线。
## 背景：`bg` 原本是个「只定义、不消费」的孤儿键（全工程 0 处调用），也没有任何地方
## 调用过 RenderingServer.set_default_clear_color —— 于是各页面露出来的其实是 Godot
## 的默认清屏色 #4C4C4C（对局页再叠一层 endgame_dim 变成 #222222），五套粉彩主题
## 换来换去只有卡片和文字在动、底色纹丝不动。
## 这里把 bg 接到全局清屏色上：一处接线覆盖**全部**页面（各页面场景的根都是裸
## Control，本来就没有背景节点，不需要逐个改 .tscn，也就不会与后续美术改动打架）。
func _apply_clear_color() -> void:
    RenderingServer.set_default_clear_color(bg())


## 【2026-09-29 新增】全局兜底文本色。
##
## 缘起：截图验收时发现选关页大标题「选择关卡」是**白字压粉彩底**（≈1.5:1），
## 几乎看不见。追下去是工程级问题：ui/ 下共有 63 处 `Label.new()`，但只有约 28 处
## 写了 font_color override —— 剩下的全靠**引擎默认主题**的白色字。旧的深色主题
## 恰好是白字，所以这个洞一直没人发现；一旦换成粉彩浅底，这些标签会成片消失。
##
## 逐个补 override 是治标的（下一次有人新加 Label 又会漏）。这里改为挂一个
## **运行时 Theme 到根 Window**：Godot 的 Theme 是链式回退的 —— 只覆盖我们定义过的
## 条目，没定义的（按钮 stylebox、Slider 纹理…）继续走引擎默认主题，所以是纯增量。
## 只覆盖「纯文本」类控件；按钮在本工程里都是显式着色的，不去动以免覆盖选中态字色。
func _apply_default_theme() -> void:
    if _default_theme == null:
        _default_theme = Theme.new()
    var t: Color = text()
    _default_theme.set_color("font_color", "Label", t)
    _default_theme.set_color("font_color", "RichTextLabel", t)
    _default_theme.set_color("default_color", "RichTextLabel", t)
    _default_theme.set_color("font_color", "LinkButton", accent())
    _default_theme.set_color("font_hover_color", "LinkButton", accent_text())
    _default_theme.set_color("font_color", "TooltipLabel", text())
    var root: Window = null
    if is_inside_tree():
        root = get_tree().root
    if root != null and root.theme != _default_theme:
        root.theme = _default_theme


# ============ 取色接口（全工程唯一合法色源） ============

func bg() -> Color:
    return _active.get("bg", _DARK.bg)

func card() -> Color:
    return _active.get("card", _DARK.card)

func cell_hidden() -> Color:
    return _active.get("cell_hidden", _DARK.cell_hidden)

func cell_revealed() -> Color:
    return _active.get("cell_revealed", _DARK.cell_revealed)

func text() -> Color:
    return _active.get("text", _DARK.text)

func text_secondary() -> Color:
    return _active.get("text_secondary", _DARK.text_secondary)

func accent() -> Color:
    return _active.get("accent", _DARK.accent)

func danger() -> Color:
    return _active.get("danger", _DARK.danger)


## 危险色的**文字**版本（2026-09-25 无障碍审计）：原 danger(#C0504D) 作 18px 正文压在
## 深色底上只有 ≈3.55:1，达不到 WCAG AA 的 4.5:1。文字场景一律用这个（提亮后 ≈6:1）；
## 图形填充（旗子 / 危险格 / 雷 / 引爆高亮）继续用 danger()——那里门槛是 3:1，原标题色够用。
func danger_text() -> Color:
    # CozyStyle 家族：danger_text 是**表中已解算好的独立键**（同一色相下压明度到 ≥4.6:1），
    # 因为那些主题的底是粉彩浅色，"提亮"只会越提越糊 —— 与 light 分支同理，故不能再套
    # lightened(0.30) 的通用公式。
    if _COZY.has(mode):
        return _active.get("danger_text", danger())
    # 分主题（2026-09-26 补的 WCAG 测试抓出的 bug）：dark 底上提亮 0.30 ≈6:1 ✓；
    # 但 light 底是**浅色**，提亮是反向操作（越提越贴近底色），实测只有 3.51:1 ❌——
    # 浅底直接用原 danger（#B71C1C 压 #F4F4F0 ≈5.9:1）即达标。
    return danger().lightened(0.30) if mode == "dark" else danger()


## 【2026-09-29 新增】accent 底上的**文字**色。
##
## 缘起：原工程在 accent 背景按钮上直接写 `font_color = text()`。深色主题下侥幸能用
## （accent #7CB9E8 偏亮），但浅色主题 accent #2D7BB0 压 #333333 只有 ≈2.0:1 —— 既存缺陷。
## CozyStyle 是「配对色」体系（每个底色都有专属字色，如 NumBtn 配 NumBtnNum、
## NumBtnSel 配 NumBtnNumSel），本次接入顺手把这条纪律补齐：凡 accent 当底，字色走本接口。
func accent_text() -> Color:
    return _active.get("accent_text", text())


## 【2026-09-29 新增】safe 当底时的字色。CozyStyle 家族里 safe 已是深青绿，两者同值；
## 独立成键是为了让未来某个主题能把"安全底"做成浅色而不用改调用点。
func safe_text() -> Color:
    return _active.get("safe_text", safe())


## WCAG 相对亮度 / 对比度。放在 ThemeManager 而不是测试里，是因为调用点也需要它
## （见 text_on）—— 这类公式一旦有两份实现就必然会漂移。
static func _lin(u: float) -> float:
    return u / 12.92 if u <= 0.04045 else pow((u + 0.055) / 1.055, 2.4)


static func contrast_ratio(a: Color, b: Color) -> float:
    var la: float = 0.2126 * _lin(a.r) + 0.7152 * _lin(a.g) + 0.0722 * _lin(a.b)
    var lb: float = 0.2126 * _lin(b.r) + 0.7152 * _lin(b.g) + 0.0722 * _lin(b.b)
    var hi: float = max(la, lb)
    var lo: float = min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


## 【2026-09-29 新增】任意底色上的**保证可读**的前景色。
##
## 缘起：工程里大量选中态/强调态把底色从 card() 换成 accent 系
## （`accent().darkened(0.5)`、`safe().darkened(0.55)`…），但字色仍然固定写 text()。
## 旧的两套主题（深/浅）各自"看着还行"，所以一直没暴露；接入五套粉彩之后同一个淡化
## 系数在五个色相上会给出完全不同的明度，固定 text() 必然有几个主题糊掉。
##
## 与其在几十个调用点各手动挑一次颜色（下一个人改配色时又会重新踩），不如把选择权
## 交给**实测对比度**：按优先级在候选前景色里挑第一个达标的，全都不达标就挑最亮的那个。
## 候选顺序即语义优先级 —— theme 自己的配对字色 > 正文色 > 纯白 > 近黑。
func text_on(base: Color, min_ratio: float = 4.5) -> Color:
    var cands: Array[Color] = [accent_text(), text(), Color.WHITE, Color("#101418")]
    var best: Color = cands[0]
    var best_ratio := -1.0
    for c in cands:
        var r: float = contrast_ratio(c, base)
        if r >= min_ratio:
            return c
        if r > best_ratio:
            best_ratio = r
            best = c
    return best


## 棋盘格线专用色（2026-09-25 无障碍审计）。
##
## 通用 `grid_line()` 是 0.20 alpha 的柔和描边，服务卡片边框；但棋盘的**相邻同色格之间
## 只靠这条线分隔** —— 0.20 压在深色底上只有 ≈1.2:1（WCAG 非文本对比要求 ≥3:1），
## 低视力玩家在一个 9×9 灰盘上看不出格子边界（审计确认）。
##
## 关键点：深色底上**不能靠加深**来提对比（黑线再黑也只到 1.3:1），必须换**浅色线**。
## 此函数只被棋盘格线使用，卡片边框仍走 grid_line，整体视觉风格不大改。
func board_grid() -> Color:
    # alpha 值经实测校准（2026-09-26）：0.34/0.42 在 **alpha 混合后**压 cell_hidden
    # 只有 2.75/2.86:1（<3 ❌）—— 旧注释的对比数字按线色直接算、没算混合，是错的。
    # 提到 0.42/0.48 后混合对比 ≈3.3/3.4:1 ✓（新补的 WCAG 测试按混合口径抓出）。
    #
    # CozyStyle 家族（2026-09-29）：线色与 alpha **都在表里解算好了** —— 保留该主题
    # BoardBg 的色相/饱和度、解出线色明度，令"浅砖之间的深缝"混合后 ≥3.5:1。
    # 注意这不是"换了个半透明色"那么简单：鼠尾草原色 #688F98 即便 α=1.0 也只有 2.63:1，
    # 必须连明度一起解才能过 3:1。
    if _COZY.has(mode):
        return _active.get("board_grid", Color(0, 0, 0, 0.48))
    return Color(1, 1, 1, 0.42) if mode == "dark" else Color(0, 0, 0, 0.48)


## 【2026-09-29 新增】棋盘「垫子」色 —— 格阵下面那块面板（CozyStyle 的 BoardBg 角色）。
##
## 为什么需要它：本工程的 cell_revealed 取的就是 GlobalBg，而 board_view 是全屏 Control、
## 根本没有棋盘背景节点 ⇒ **已翻开的格与页面底色完全同色**，棋盘的边界只剩 1px 格线在
## 暗示。CozyStyle 的 9×9 格阵之所以读起来是"一个物件"，靠的就是它有块专属面板色。
##
## 数值说明：原角色值对 GlobalBg 只有 2.47:1（海盐 #657DA0），低于本工程对非文本相邻色
## 的 3:1 口径 ⇒ 保留色相/饱和度、只解明度，到 3.4:1（留 0.4 余量）。
## dark/light 返回全透明 = **不画垫子**，旧主题观感零变化。
func board_mat() -> Color:
    if _COZY.has(mode):
        return _active.get("board_mat", Color(0, 0, 0, 0))
    return Color(0, 0, 0, 0)


## 【2026-09-29 新增】动物伙伴（占位猫）专用取色。
##
## 为什么 CozyStyle 的 50 个角色里一个都用不上：那 50 个全是 **UI 角色**
## （按钮、格子、数字、边框、状态…），整套体系里**没有任何一个"生物/角色"色**。
## 直接拿 BoardBg 当猫毛会得到一块和棋盘同色的色斑，猫会消失。
##
## 所以 pet_* 是**新解算的一族**（见 _pv/derive_cozy.py 的 solve_side + P1..P8 护栏）：
## 色相借自**该主题自己的**角色（毛 ← BoardBg 色相、鼻 ← 暖色带中离毛色相最远的点、
## 叶 ← 工程既有的 safe 绿），明度则解到"刚好压过门槛"的那一档 —— 这正是
## CozyStyle 低对比的习惯，不是随手挑的漂亮色。
##
## 键名：fur / fur_2 / patch / ink / eye / pupil / nose / leaf / leaf_2 / shadow
## （调用方传短键，此处补 "pet_" 前缀）。
##
## 旧主题（dark / light）没有这一族 —— 就地派生一族而不是全落 text()：
## 全落 text() 会把猫压成一块**纯剪影**（连眼睛、鼻子、草地上不了色，因为都同色），
## 而伙伴是要能看出"是只猫"的。派生值直接复用手边已有的角色，观感不如 CozyStyle 的
## 专用解算，但保住了最低限度的可读性。这两套主题的 hex 被 test_theme_settings.gd
## 逐字钉着、不能顺手改 ⇒ 派生是这里唯一可行的做法。
func pet_c(key: String) -> Color:
    if _active.has("pet_" + key):
        return _active["pet_" + key]
    # 旧主题（dark / light）没有 pet_* 族（它们的 hex 被 test_theme_settings.gd 逐字钉着、
    # 不能为伙伴顺手加键）⇒ 就地派生。派生只做两件事：**选对方向** + **解够对比度**。
    #
    # 为什么不能像第一版那样写死系数（ink = bg.darkened(0.35) 那一类）：那等于把"够不够
    # 分得开"交给运气。实测亮色主题的 bg 本来就接近白，bg.darkened(0.35) 比毛色**更亮**
    # （1.33:1，整只猫糊成一块剪影）；dark 主题的鼻子借 danger 也只有 1.33:1；
    # 亮色主题的口鼻斑 lightened(0.35) 只有 1.20:1。现在改成"以配对护栏为目标解明度"，
    # 与 _pv/derive_cozy.py 给 CozyStyle 解明度是同一套做法 ⇒ dark / light 受**同一套**
    # P1..P8 约束（守卫见 test_companion_pet.gd，7 套主题一个门槛表）。
    var fur := text_secondary()
    var page := bg()
    match key:
        "fur":
            return fur
        "fur_2":
            return fur.darkened(0.18)
        # 口鼻斑：朝**页面底色**推（浅底变亮、深底变暗），解得 ⊥毛 ≥1.6（护栏 1.4）。
        "patch":
            return _pet_solve(fur, page, fur, 1.6)
        # 描边：朝**背离页面**的那一端推 —— 它同时要压住毛色和页面底色。深色主题下这给出
        # 一条近白描边，这不是取巧：bg #1E1E24 的亮度已接近 0，没有更暗的地方可去，
        # 深色底上的描边本来就只能往亮走（CozyStyle 那套是浅底，才用深墨）。
        "ink":
            return _pet_solve(fur, _pet_extreme(page), fur, 3.2)
        "eye":
            return Color.WHITE
        # 虹膜：起点是毛色压暗一档（多数主题下已够线 ⇒ 解出的 t≈0，即"不动"），
        # 不够才继续朝黑推，解得 ⊥眼白 ≥6.0（护栏 4.5）。
        "pupil":
            return _pet_solve(fur.darkened(0.35), Color.BLACK, Color.WHITE, 6.0)
        # 鼻子：色相必须留在暖色（红鼻子是解剖事实），只解明度 —— 朝背离毛色的那一侧推。
        "nose":
            return _pet_solve(danger(), _pet_away(danger(), fur), fur, 1.7)
        "leaf":
            return safe()
        # 两色叶：同色系推深一档（护栏 1.2）。
        "leaf_2":
            return _pet_solve(safe(), Color.BLACK, safe(), 1.35)
        "shadow":
            return Color(0, 0, 0, 0.16)
    return text()


## 背离 ref 的那一端（比 ref 暗就往黑走，比 ref 亮就往白走）。
## 用于"只许改明度、不许动色相"的角色（鼻子）。
func _pet_away(base: Color, ref: Color) -> Color:
    return Color.BLACK if base.get_luminance() <= ref.get_luminance() else Color.WHITE


## 页面底色的**对立极端**：底色偏亮 ⇒ 描边往黑走，底色偏暗 ⇒ 往白走。
func _pet_extreme(page: Color) -> Color:
    return Color.WHITE if page.get_luminance() < 0.5 else Color.BLACK


## 把 from 沿 toward 推进到 ⊥ref ≥ target，返回恰好越线的那个值（二分 24 步）。
##
## 与 _pv/derive_cozy.py 的 solve_side 是同一套做法（受门禁约束的角色按目标解明度），
## 只是直接对 Color 二分 —— 更短，也不必假设 sRGB 分段公式的形状。toward 比 ref 更极端时
## 对比度沿 t 单调不减，故二分成立。
##
## ⚠️ 可行性判断必须拿 **ref** 比，不能拿 from 比：toward 本身对 ref 都不够时才是真的无解
##    （此时返回 toward，尽力而为）。第一版写成对比 from，于是"起点已经够线、只需保持不动"
##    被误判成无解而直接跳到纯黑（虹膜曾因此整块变黑）。
func _pet_solve(from: Color, toward: Color, ref: Color, target: float) -> Color:
    if contrast_ratio(toward, ref) <= target:
        return toward
    var lo := 0.0
    var hi := 1.0
    for _i in 24:
        var mid := (lo + hi) * 0.5
        if contrast_ratio(from.lerp(toward, mid), ref) >= target:
            hi = mid
        else:
            lo = mid
    return from.lerp(toward, hi)

## 提示「必安全」高亮色（§8.4 扩展：提示系统用色）
func safe() -> Color:
    return _active.get("safe", _DARK.safe)

func grid_line() -> Color:
    return _active.get("grid_line", _DARK.grid_line)

## §8.4.3 线索数字配色；n ∈ 1..8（0 = 空白不绘制，不在此处理）
func number(n: int) -> Color:
    if _skin_numbers.size() >= 8 and n >= 1 and n <= 8:
        return _skin_numbers[n - 1]
    if n < 1 or n > 8:
        return text()
    # CozyStyle 家族：8 色表随主题走（色相固定，饱和度按主题档位缩放，明度逐主题解到
    # 压在 cell_revealed 上 ≥4.6:1）。
    if _COZY_NUM.has(mode):
        return (_COZY_NUM[mode] as Array)[n - 1]
    var arr := _NUM_DARK if mode == "dark" else _NUM_LIGHT
    return arr[n - 1]

func mine_body() -> Color:
    return _active.get("mine_body", _OVERLAY_DARK.mine_body)

func hover_center_overlay() -> Color:
    return _active.get("hover_center", _OVERLAY_DARK.hover_center)

func hover_neighbor_overlay() -> Color:
    return _active.get("hover_neighbor", _OVERLAY_DARK.hover_neighbor)

func endgame_dim() -> Color:
    return _active.get("endgame_dim", _OVERLAY_DARK.endgame_dim)
