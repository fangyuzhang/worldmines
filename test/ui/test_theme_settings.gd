# test_theme_settings.gd —— T1 默认值 / T2 setter 持久化 / T3 损坏容错【plan1.1 §10.12.4】
# 用例纪律：headless 可跑；before_each 清理 user:// 测试产物。
# SettingsManager 是 autoload 实例名（非 class_name），测试用脚本实例化。
extends GutTest

const CFG := "user://settings.cfg"
const SCRIPT := "res://ui/settings_manager.gd"


func before_each() -> void:
    _rm(CFG)
    SettingsManager.theme_mode = "system"
    SettingsManager.ripple_enabled = true
    SettingsManager.hover_highlight = true
    SettingsManager.autosave_enabled = true
    SettingsManager.keyboard_enabled = true


func after_each() -> void:
    _rm(CFG)


func _rm(path: String) -> void:
    if FileAccess.file_exists(path):
        DirAccess.remove_absolute(path)


func _new_sm() -> Node:
    var gd: GDScript = load(SCRIPT)
    var sm: Node = gd.new()
    return sm


# T1：5 项默认值正确（无 cfg 文件 → 全默认）
func test_t1_defaults() -> void:
    var sm: Node = _new_sm()
    sm.load_cfg()
    assert_eq(sm.get("theme_mode"), "system")
    assert_eq(sm.get("ripple_enabled"), true)
    assert_eq(sm.get("hover_highlight"), true)
    assert_eq(sm.get("autosave_enabled"), true)
    assert_eq(sm.get("keyboard_enabled"), true)
    sm.free()


# T2：setter → 存盘 → 新实例读回一致
func test_t2_setter_persists() -> void:
    var sm: Node = _new_sm()
    sm.load_cfg()
    sm.set_theme_mode("light")
    sm.set_ripple_enabled(false)
    sm.set_hover_highlight(false)
    sm.set_autosave_enabled(false)
    sm.set_keyboard_enabled(false)
    assert_true(FileAccess.file_exists(CFG), "cfg 应已写盘")

    var sm2: Node = _new_sm()
    sm2.load_cfg()
    assert_eq(sm2.get("theme_mode"), "light")
    assert_eq(sm2.get("ripple_enabled"), false)
    assert_eq(sm2.get("hover_highlight"), false)
    assert_eq(sm2.get("autosave_enabled"), false)
    assert_eq(sm2.get("keyboard_enabled"), false)
    sm.free()
    sm2.free()


# T3：坏 cfg → 加载回默认值不崩溃
func test_t3_corrupted_cfg_fallback() -> void:
    var f := FileAccess.open(CFG, FileAccess.WRITE)
    f.store_string("{{{ 不是合法 ConfigFile !!!")
    f.close()
    var sm: Node = _new_sm()
    sm.load_cfg()  # 不崩溃即通过（ConfigFile.load 解析失败 → 保持默认）
    assert_eq(sm.get("theme_mode"), "system")
    assert_eq(sm.get("ripple_enabled"), true)
    sm.free()


# 附加：ThemeManager 色板表抽查（§8.4.1~8.4.3 照抄校验）
# 经 _palette_for 切换（绕过 300ms tween，测试直取目标色板）
func test_theme_palette_dark() -> void:
    ThemeManager.mode = "dark"
    ThemeManager._target = ThemeManager._palette_for("dark")
    ThemeManager._active = ThemeManager._target.duplicate()
    assert_eq(ThemeManager.bg(), Color("#1E1E24"))
    assert_eq(ThemeManager.cell_hidden(), Color("#3A3A42"))
    assert_eq(ThemeManager.danger(), Color("#C0504D"))
    assert_eq(ThemeManager.number(1), Color("#5FA8E8"))
    assert_eq(ThemeManager.number(8), Color("#9494A0"))


func test_theme_palette_light() -> void:
    ThemeManager.mode = "light"
    ThemeManager._target = ThemeManager._palette_for("light")
    ThemeManager._active = ThemeManager._target.duplicate()
    assert_eq(ThemeManager.bg(), Color("#F4F4F0"))
    assert_eq(ThemeManager.accent(), Color("#2D7BB0"))
    assert_eq(ThemeManager.number(3), Color("#C0392B"))
    # 还原深色，避免污染其他测试
    ThemeManager.mode = "dark"
    ThemeManager._target = ThemeManager._palette_for("dark")
    ThemeManager._active = ThemeManager._target.duplicate()
