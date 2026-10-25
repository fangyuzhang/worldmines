# test_settings_popup.gd —— 对局内设置弹窗
# 验证：可构建、含主题/开关控件、切换开关立即经 SettingsManager 生效（对局内实时开关）。
extends GutTest

var _popup: PopupPanel


func before_each() -> void:
	_popup = load("res://ui/settings_popup.tscn").instantiate()
	add_child_autofree(_popup)


func test_sp1_builds_controls() -> void:
	assert_not_null(_popup, "弹窗应能实例化")
	assert_not_null(_popup._theme_opt, "应有主题选项")
	assert_not_null(_popup._ripple_chk, "应有涟漪开关")
	assert_not_null(_popup._hover_chk, "应有悬停开关")
	assert_not_null(_popup._autosave_chk, "应有自动存档开关")
	assert_not_null(_popup._keyboard_chk, "应有键盘开关")
	assert_not_null(_popup._sfx_chk, "应有音效开关")


func test_sp2_toggle_sfx_applies_immediately() -> void:
	var before: bool = SettingsManager.sfx_enabled
	_popup._sfx_chk.button_pressed = not before
	assert_eq(SettingsManager.sfx_enabled, not before, "切换音效应立即生效")
	assert_eq(AudioManager.enabled, not before, "音效开关应同步 AudioManager")
	# 还原现场
	SettingsManager.set_sfx_enabled(before)


func test_sp3_toggle_hover_applies_immediately() -> void:
	var before: bool = SettingsManager.hover_highlight
	_popup._hover_chk.button_pressed = not before
	assert_eq(SettingsManager.hover_highlight, not before, "切换悬停高亮应立即生效")
	SettingsManager.set_hover_highlight(before)
