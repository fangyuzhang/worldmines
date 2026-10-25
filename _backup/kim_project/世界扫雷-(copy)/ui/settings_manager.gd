# settings_manager.gd —— 设置持久化（5 项，实时生效）【plan1.1 §10.7.2】
# 设置实时生效：改即存盘即广播；UI 面板控件只调 setter，不直改变量。
extends Node
## autoload 名：SettingsManager

signal settings_changed

const PATH := "user://settings.cfg"

var theme_mode: String = "system"  # "system" | "dark" | "light"
var ripple_enabled: bool = true
var hover_highlight: bool = true
var autosave_enabled: bool = true
var keyboard_enabled: bool = true
var sfx_enabled: bool = true
var drawing_opacity: float = 1.0  # 绘画层透明度 0.5~1.0
var active_skin: String = ""      # 激活的皮肤 id（"" = 内置主题）
# 提示浮动窗口（HintPanel）：位置 / 大小 / 字体大小
var hint_font_size: int = 16
var hint_window_pos: Vector2 = Vector2.ZERO
var hint_window_size: Vector2 = Vector2(320, 200)
# 窗口模式：true = 独占全屏；false = 窗口模式（可调整大小）
var fullscreen: bool = false


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
    active_skin = _get_str(cfg, "active_skin", "")
    hint_font_size = int(cfg.get_value("game", "hint_font_size", 16))
    hint_window_pos = cfg.get_value("game", "hint_window_pos", Vector2.ZERO)
    hint_window_size = cfg.get_value("game", "hint_window_size", Vector2(320, 200))
    fullscreen = _get_bool(cfg, "fullscreen", false)
    AudioManager.enabled = sfx_enabled


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
    cfg.set_value("game", "active_skin", active_skin)
    cfg.set_value("game", "hint_font_size", hint_font_size)
    cfg.set_value("game", "hint_window_pos", hint_window_pos)
    cfg.set_value("game", "hint_window_size", hint_window_size)
    cfg.set_value("game", "fullscreen", fullscreen)
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


## 切换全屏 / 窗口模式：立即生效 + 持久化 + 广播（与其余 setter 同构）
func set_fullscreen(v: bool) -> void:
    fullscreen = v
    _apply_window_mode()
    save()
    settings_changed.emit()


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
