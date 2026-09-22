# test_ui_confirm.gd —— 破坏性操作的二次确认口径
#
# R 键与 HUD「重开」共用同一套规则，规则错了就是
# 「要么每次都弹窗打断操作、要么误点一次丢整局」，必须锁死。
#
# 2026-09-22 变更：「关卡列表 / 主菜单」（离开对局）**不再走确认框**——用户决策改为
# 自动保存 + 直接离开。原 c4/c5 两个离开用例随 confirm_leave 退役，换成 c4 源码级守卫。
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


## 2026-09-22 用户决策：从对局返回选关 / 主菜单**不再弹确认框**，改为自动保存后直接离开。
## 原 c4/c5（离开确认的两个行为用例）随 confirm_leave 一并退役，这里换成源码级守卫：
## ① UiConfirm 不得再出现 confirm_leave；② 两个离开入口（HUD 直点 / 暂停菜单）都走 save_now
## 且不再引用确认框。
## 为什么用源码断言而不是行为断言：离开流程横跨 HUD / 暂停菜单 / 场景切换三类节点，
## 行为测试的搭建成本远高于收益；而本需求的核心不变量——「离开不再打断、且不再丢进度」——
## 恰好能直接从这三份源码里读出来。若未来要恢复确认框，请先改本测试并写明原因。
func test_c4_leave_never_confirms_and_always_autosaves() -> void:
	# 判据用 "func confirm_leave"（函数定义）而非裸函数名：三处文件的历史注释里
	# 会提到 confirm_leave（说明退役原因），那是文档不是实现——不应误伤。
	var confirm_src := FileAccess.get_file_as_string("res://ui/ui_confirm.gd")
	assert_false(confirm_src.contains("func confirm_leave"),
		"UiConfirm 不应再有「离开确认」——离开不再弹窗（自动保存 + 直接离开）")
	for path in ["res://ui/hud.gd", "res://ui/pause_menu.gd"]:
		var src := FileAccess.get_file_as_string(path)
		assert_true(src.contains("save_now"),
			"%s 的离开路径应自动保存进度（GameSession.save_now）" % path)
		assert_false(src.contains("func confirm_leave"),
			"%s 不应再弹离开确认框" % path)
