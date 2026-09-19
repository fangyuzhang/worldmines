# settings_manager.gd —— 设置持久化（5 项，实时生效）【plan1.1 §10.7.2】
# 设置实时生效：改即存盘即广播；UI 面板控件只调 setter，不直改变量。
extends Node
## autoload 名：SettingsManager

signal settings_changed

const PATH := "user://settings.cfg"

var theme_mode: String = "system"  # "system" | "dark" | "light"
## 翻开动效**总闸**（波浪涟漪 + 后续单格 pop 都归它管）：关则翻开不播任何动效；默认开。
## ★ 这是唯一的翻开动效开关，不要再新加第二层同类开关（用户只想要一个）。
var ripple_enabled: bool = true
var hover_highlight: bool = true
var autosave_enabled: bool = true
var keyboard_enabled: bool = true
var sfx_enabled: bool = true
var drawing_opacity: float = 1.0  # 绘画层透明度 0.5~1.0
## 绘画草稿是否写入存档（用户可选）：关闭后自动存档/终局存档不带 drawing 字段，
## 恢复对局也不还原草稿（棋盘进度照常存取）。
var drawing_in_save: bool = true
var active_skin: String = ""      # 激活的皮肤 id（"" = 内置主题）
# 提示浮动窗口（HintPanel）：位置 / 大小 / 字体大小
var hint_font_size: int = 16
var hint_window_pos: Vector2 = Vector2.ZERO
var hint_window_size: Vector2 = Vector2(320, 200)
# 提示三档（对齐对标游戏 doc10 §3.2）：
#   0 = 标准（给出结论格 + 依据线索）
#   1 = 弱提示（只高亮「要用到的线索」，不显示可推格，玩家自己推）
#   2 = 禁用（完全关闭提示）
var hint_mode: int = 0
# 免费提示充能：开启后提示按钮按 120 秒周期充能；
# 充满时用提示不影响「完美通关」，未充满即用则标记本局为非完美（对标 doc10 §3.2）。
var hint_charge: bool = true
# 无猜模式（对标 doc10 §2）：0=关闭 / 1=专家（禁止猜测：拒绝翻开推不出来的格）。
# 红线兼容实现——不移动雷位，故不破坏 R01 与关卡数据；详见 GameSession 同名小节注释。
var no_guess_mode: int = 0
# ---- 终极模式附加开关（对标 doc10 §2.3）----
# 终极模式下默认「游戏前期隐藏总雷数」（doc 原文），故默认隐藏。
var ult_hide_mines: bool = true
# 勾选则不给「剩余可断定格数」信息（doc: AddOnEarlyMineCount）；默认隐藏。
var ult_hide_deducible: bool = true
# 勾选则「剩余可推格数为 0 时自动按下提示按钮」（doc: AddOnAutoReveal）。
var ult_auto_reveal: bool = false
# ★ 已决策（v2.9.3）：doc 的 AddOnSecondary「必须标出副板格」**明确不引入**。
# 依据：本作是「单盘面 + 变体/全局规则组合」架构，不存在对标游戏那种同屏并置的
# 「主板/副板」双盘面；该机制依赖于对标游戏特有的关卡结构，移植过来没有可约束的对象。
# 教程文本格式里的空单元格只是**视觉留白**（分组展示用），不是需要被标记的副盘面。
# 若日后真要做双盘面对照（例如对称类规则的对照盘），应作为独立特性重新设计，
# 而不是把这个开关塞进终极模式。
# 窗口模式：true = 独占全屏；false = 窗口模式（可调整大小）
var fullscreen: bool = false
# 连携操作（市面扫雷标配的两个快捷手势）：
#   · 一键展开 chord：点已翻开的数字格（或中键 / 空格），若邻域旗数 == 线索值则展开其余邻格
#   · 右键拖动连续插旗
# 默认开启；若真机反馈「误触太多」可在此关闭（两者绑定一个开关，避免设置项膨胀）。
var quick_actions: bool = true
# 重开确认弹窗：玩家在弹窗勾选「不再提示」后置 false，重开直接执行（v3.3）。
var restart_confirm: bool = true


func _ready() -> void:
    load_cfg()
    ## 启动时按持久化的用户设置应用窗口模式（延迟等 DisplayServer 就绪，避免被引擎覆盖）
    _apply_window_mode.call_deferred()
    ## 监听窗口尺寸变化：每次 resize 强制重设 content scale，
    ## 避免 mode 切换/外部因素导致 canvas_items 缩放失效。
    var win := _root_window()
    if win != null and not win.size_changed.is_connected(_apply_content_scale):
        win.size_changed.connect(_apply_content_scale)


## 加载方法名用 load_cfg()，避开保留字歧义（裁决档案 A.1-3）。
func load_cfg() -> void:
    var cfg := ConfigFile.new()
    if cfg.load(PATH) != OK:
        return  # 文件不存在 → 按默认值
    theme_mode = _get_str(cfg, "theme_mode", "system")
    ripple_enabled = _get_bool(cfg, "ripple_enabled", true)
    hover_highlight = _get_bool(cfg, "hover_highlight", true)
    autosave_enabled = _get_bool(cfg, "autosave_enabled", true)
    keyboard_enabled = _get_bool(cfg, "keyboard_enabled", true)
    sfx_enabled = _get_bool(cfg, "sfx_enabled", true)
    drawing_opacity = clampf(float(cfg.get_value("game", "drawing_opacity", 1.0)), 0.5, 1.0)
    drawing_in_save = _get_bool(cfg, "drawing_in_save", true)
    active_skin = _get_str(cfg, "active_skin", "")
    hint_font_size = int(cfg.get_value("game", "hint_font_size", 16))
    hint_window_pos = cfg.get_value("game", "hint_window_pos", Vector2.ZERO)
    hint_window_size = cfg.get_value("game", "hint_window_size", Vector2(320, 200))
    hint_mode = clampi(int(cfg.get_value("game", "hint_mode", 0)), 0, 2)
    hint_charge = _get_bool(cfg, "hint_charge", true)
    no_guess_mode = clampi(int(cfg.get_value("game", "no_guess_mode", 0)), 0, 2)
    ult_hide_mines = _get_bool(cfg, "ult_hide_mines", true)
    ult_hide_deducible = _get_bool(cfg, "ult_hide_deducible", true)
    ult_auto_reveal = _get_bool(cfg, "ult_auto_reveal", false)
    fullscreen = _get_bool(cfg, "fullscreen", false)
    quick_actions = _get_bool(cfg, "quick_actions", true)
    restart_confirm = _get_bool(cfg, "restart_confirm", true)
    # 注：AudioManager.enabled 的开机同步已移入 AudioManager._ready——本 autoload 注册序(4)
    # 早于 AudioManager(7)，此处反向引用会因 _ready 时序失败，导致持久化的音效开关开机不生效；
    # 且测试手工实例化 SettingsManager 调 load_cfg 时不应产生改写真实 AudioManager 的全局副作用。


func _get_str(cfg: ConfigFile, key: String, fallback: String) -> String:
    var v: Variant = cfg.get_value("game", key, fallback)
    return str(v) if v != null else fallback


func _get_bool(cfg: ConfigFile, key: String, fallback: bool) -> bool:
    var v: Variant = cfg.get_value("game", key, fallback)
    return bool(v) if v is bool else fallback


func save() -> void:
    var cfg := ConfigFile.new()
    cfg.set_value("game", "theme_mode", theme_mode)
    cfg.set_value("game", "ripple_enabled", ripple_enabled)
    cfg.set_value("game", "hover_highlight", hover_highlight)
    cfg.set_value("game", "autosave_enabled", autosave_enabled)
    cfg.set_value("game", "keyboard_enabled", keyboard_enabled)
    cfg.set_value("game", "sfx_enabled", sfx_enabled)
    cfg.set_value("game", "drawing_opacity", drawing_opacity)
    cfg.set_value("game", "drawing_in_save", drawing_in_save)
    cfg.set_value("game", "active_skin", active_skin)
    cfg.set_value("game", "hint_font_size", hint_font_size)
    cfg.set_value("game", "hint_window_pos", hint_window_pos)
    cfg.set_value("game", "hint_window_size", hint_window_size)
    cfg.set_value("game", "hint_mode", hint_mode)
    cfg.set_value("game", "hint_charge", hint_charge)
    cfg.set_value("game", "no_guess_mode", no_guess_mode)
    cfg.set_value("game", "ult_hide_mines", ult_hide_mines)
    cfg.set_value("game", "ult_hide_deducible", ult_hide_deducible)
    cfg.set_value("game", "ult_auto_reveal", ult_auto_reveal)
    cfg.set_value("game", "fullscreen", fullscreen)
    cfg.set_value("game", "quick_actions", quick_actions)
    cfg.set_value("game", "restart_confirm", restart_confirm)
    cfg.save(PATH)


# ============ setter（赋值 → save → 广播；实时生效） ============

func set_theme_mode(v: String) -> void:
    theme_mode = v
    save()
    settings_changed.emit()


func set_ripple_enabled(v: bool) -> void:
    ripple_enabled = v
    save()
    settings_changed.emit()


func set_hover_highlight(v: bool) -> void:
    hover_highlight = v
    save()
    settings_changed.emit()


func set_autosave_enabled(v: bool) -> void:
    autosave_enabled = v
    save()
    settings_changed.emit()


func set_keyboard_enabled(v: bool) -> void:
    keyboard_enabled = v
    save()
    settings_changed.emit()


func set_sfx_enabled(v: bool) -> void:
    sfx_enabled = v
    AudioManager.enabled = v
    save()
    settings_changed.emit()


func set_drawing_opacity(v: float) -> void:
    drawing_opacity = clampf(v, 0.5, 1.0)
    save()
    settings_changed.emit()


func set_drawing_in_save(v: bool) -> void:
    drawing_in_save = v
    save()
    settings_changed.emit()
    if not v:
        # 关闭即删除已持久化的全部草稿（用户预期：关闭 = 不再保留任何草稿）
        SaveCoordinator.clear_all_drawings()


## 仅应用不落盘（滑条拖动的 value_changed 每刻度触发——落盘放 drag_ended，避免一次拖动几十次全量写盘）
func apply_drawing_opacity(v: float) -> void:
    drawing_opacity = clampf(v, 0.5, 1.0)
    settings_changed.emit()


func set_active_skin(v: String) -> void:
    active_skin = v
    save()
    settings_changed.emit()


func set_hint_font_size(v: int) -> void:
    hint_font_size = v
    save()


func set_hint_window_pos(v: Vector2) -> void:
    hint_window_pos = v
    save()


func set_hint_window_size(v: Vector2) -> void:
    hint_window_size = v
    save()


func set_hint_mode(v: int) -> void:
    hint_mode = clampi(v, 0, 2)
    save()


func set_hint_charge(v: bool) -> void:
    hint_charge = v
    save()


func set_no_guess_mode(v: int) -> void:
    no_guess_mode = clampi(v, 0, 2)
    save()


func set_ult_hide_mines(v: bool) -> void:
    ult_hide_mines = v
    save()


func set_ult_hide_deducible(v: bool) -> void:
    ult_hide_deducible = v
    save()


func set_ult_auto_reveal(v: bool) -> void:
    ult_auto_reveal = v
    save()


## 切换全屏 / 窗口模式：立即生效 + 持久化 + 广播（与其余 setter 同构）
func set_fullscreen(v: bool) -> void:
    fullscreen = v
    _apply_window_mode()
    save()
    settings_changed.emit()


func set_quick_actions(v: bool) -> void:
    quick_actions = v
    save()
    settings_changed.emit()


func set_restart_confirm(v: bool) -> void:
    restart_confirm = v
    save()


## 获取 root window。autoload 下 get_window() 在嵌入/多窗口场景可能返回非主窗口对象，
## 导致 mode/content_scale 设置落空；直接用 SceneTree.root 更可靠。
func _root_window() -> Window:
    var tree := get_tree()
    return tree.root as Window if tree != null else null


## 仅强制设置 content scale（canvas_items 整体缩放 + expand 无黑边 + 分数缩放）。
## 独立成函数，供 _ready / _apply_window_mode / size_changed 多处调用。
func _apply_content_scale() -> void:
    var win := _root_window()
    if win == null:
        return
    var vp_w := int(ProjectSettings.get_setting("display/window/size/viewport_width", 1280))
    var vp_h := int(ProjectSettings.get_setting("display/window/size/viewport_height", 720))
    win.content_scale_size = Vector2i(vp_w, vp_h)
    win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
    win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
    win.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL


## 把当前 fullscreen 设置应用到窗口（运行时强制，实时生效）。
## 1) content scale：显式设 canvas_items（整体等比缩放 + expand 无黑边）。
##    不依赖 project.godot 的 stretch 设置在运行时是否已生效——规避
##    Godot 4.x 中 stretch 未加载/缓存导致「拖拽窗口内容不缩放」的问题。
## 2) fullscreen=true ⇒ 全屏（无边框铺满屏幕）；false ⇒ 窗口模式（可自由调整大小）。
## 三设：先 content scale，再切 mode，再 content scale（mode 切换可能重置 scale）。
## mode 用 DisplayServer 底层 API + Window.mode 双写，规避被静默拒绝的情况。
func _apply_window_mode() -> void:
    var win := _root_window()
    if win == null:
        return
    _apply_content_scale()
    DisplayServer.window_set_mode(
        DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
    )
    win.mode = Window.MODE_FULLSCREEN if fullscreen else Window.MODE_WINDOWED
    _apply_content_scale()  # mode 切换后再设一次，避免被 reset
