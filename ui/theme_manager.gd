# theme_manager.gd —— 取色中枢（全工程唯一合法色源）【plan1.1 §10.7.1】
# 色板照抄 plan1.1 §8.4.1~8.4.4，任何其他文件禁止出现硬编码 RGB。
# 主题切换：300ms Tween 逐色 lerp，每步广播 theme_changed，不中断对局。
extends Node
## autoload 名：ThemeManager

signal theme_changed

## 实际生效模式："dark" | "light"
var mode: String = "dark"

var _active := {}  # 当前生效色板（插值期间为即时值）
var _target := {}  # 目标色板
var _tween: Tween

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


func _ready() -> void:
    mode = _settings_mode()
    _target = _palette_for(mode)
    _active = _target.duplicate()
    if SettingsManager != null:
        SettingsManager.settings_changed.connect(_on_settings)


func _settings_mode() -> String:
    var want := "dark"
    if SettingsManager != null and SettingsManager.theme_mode != null:
        want = SettingsManager.theme_mode
    if want == "dark" or want == "light":
        return want
    # "system"：Godot 4.7 无可靠系统暗色检测接口 → 按文档降级深色（§8.4.6）
    return "dark"


func _palette_for(m: String) -> Dictionary:
    var base := (_DARK if m == "dark" else _LIGHT).duplicate()
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
    if base_mode == "dark" or base_mode == "light":
        mode = base_mode
    _retarget()


## 清除皮肤，回到内置主题；base_mode 可同时切换内置底版。
func clear_skin(base_mode: String = "") -> void:
    skin_id = ""
    _skin_colors = {}
    _skin_numbers = []
    if base_mode == "dark" or base_mode == "light":
        mode = base_mode
    _retarget()


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
        if _target.has(k) and _active.has(k):
            _active[k] = (_active[k] as Color).lerp(_target[k], frac)
    theme_changed.emit()


func _apply_final() -> void:
    _active = _target.duplicate()
    theme_changed.emit()


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
    # 分主题（2026-09-26 补的 WCAG 测试抓出的 bug）：dark 底上提亮 0.30 ≈6:1 ✓；
    # 但 light 底是**浅色**，提亮是反向操作（越提越贴近底色），实测只有 3.51:1 ❌——
    # 浅底直接用原 danger（#B71C1C 压 #F4F4F0 ≈5.9:1）即达标。
    return danger().lightened(0.30) if mode == "dark" else danger()


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
    return Color(1, 1, 1, 0.42) if mode == "dark" else Color(0, 0, 0, 0.48)

## 提示「必安全」高亮色（§8.4 扩展：提示系统用色）
func safe() -> Color:
    return _active.get("safe", _DARK.safe)

func grid_line() -> Color:
    return _active.get("grid_line", _DARK.grid_line)

## §8.4.3 线索数字配色；n ∈ 1..8（0 = 空白不绘制，不在此处理）
func number(n: int) -> Color:
    if _skin_numbers.size() >= 8 and n >= 1 and n <= 8:
        return _skin_numbers[n - 1]
    var arr := _NUM_DARK if mode == "dark" else _NUM_LIGHT
    if n < 1 or n > 8:
        return text()
    return arr[n - 1]

func mine_body() -> Color:
    return _active.get("mine_body", _OVERLAY_DARK.mine_body)

func hover_center_overlay() -> Color:
    return _active.get("hover_center", _OVERLAY_DARK.hover_center)

func hover_neighbor_overlay() -> Color:
    return _active.get("hover_neighbor", _OVERLAY_DARK.hover_neighbor)

func endgame_dim() -> Color:
    return _active.get("endgame_dim", _OVERLAY_DARK.endgame_dim)
