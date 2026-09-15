# test_ui_confirm.gd —— 破坏性操作的二次确认口径
#
# R 键与 HUD「重开 / 关卡列表 / 主菜单」共用同一套规则，规则错了就是
# 「要么每次都弹窗打断操作、要么误点一次丢整局」，必须锁死。
extends GutTest

var _host: Control


func before_each() -> void:
	_host = Control.new()
	add_child_autofree(_host)


func _dialog() -> ConfirmationDialog:
	for c in _host.get_children():
		if c is ConfirmationDialog:
			return c
	return null


# 注意：GDScript 的 lambda **按值捕获**外部局部变量，在 lambda 里写
# `called = true` 改不到外面。用数组/字典作为可变容器来记录调用。
func test_c1_restart_skips_confirm_when_no_progress() -> void:
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	GameSession.elapsed = 0.0
	var calls: Array = []
	UiConfirm.confirm_restart(_host, func(): calls.append("ok"))
	assert_eq(calls.size(), 1, "开局秒重开不应弹窗打断")
	assert_null(_dialog(), "免确认路径不应创建弹窗")


func test_c2_restart_confirms_when_in_progress() -> void:
	assert_true(GameSession.start_level("res://levels/classic_01.json"))
	GameSession.elapsed = 10.0
	var calls: Array = []
	UiConfirm.confirm_restart(_host, func(): calls.append("ok"))
	assert_eq(calls.size(), 0, "已有进度时不得直接执行")
	var dlg := _dialog()
	assert_not_null(dlg, "应弹出二次确认")
	dlg.get_ok_button().pressed.emit()
	assert_eq(calls.size(), 1, "确认后应执行回调")


func test_c3_restart_cancel_does_nothing() -> void:
	assert_true(GameSession.start_level("res://levels/classic_01.json"))
	GameSession.elapsed = 10.0
	var calls: Array = []
	UiConfirm.confirm_restart(_host, func(): calls.append("ok"))
	var dlg := _dialog()
	assert_not_null(dlg)
	dlg.get_cancel_button().pressed.emit()
	assert_eq(calls.size(), 0, "取消后不得执行危险操作")


func test_c4_leave_skips_confirm_when_not_playing() -> void:
	GameSession.state = GameSession.State.IDLE
	var calls: Array = []
	UiConfirm.confirm_leave(_host, func(): calls.append("ok"))
	assert_eq(calls.size(), 1, "没有进行中的对局就不该拦")
	assert_null(_dialog())


func test_c5_leave_confirms_when_playing() -> void:
	assert_true(GameSession.start_level("res://levels/classic_01.json"))
	var calls: Array = []
	UiConfirm.confirm_leave(_host, func(): calls.append("ok"))
	assert_eq(calls.size(), 0)
	var dlg := _dialog()
	assert_not_null(dlg, "进行中离开应二次确认")
	assert_true("用时" in dlg.dialog_text, "确认文案应带已用时，让玩家知道代价")
