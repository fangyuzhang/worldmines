# ui_confirm.gd —— 二次确认弹窗统一入口
#
# 背景：R 键「重开」是**立即不可撤销**的破坏性操作（清空当前进度从头开始），
# 需要统一外观 / 文案 / 判定口径的确认框（R 键与 HUD 重开按钮共用同一套
# 「毫无进展就免确认」的规则）。
#
# 历史：本模块曾有 confirm_leave（「关卡列表 / 主菜单」的离开确认）。
# 2026-09-22 用户决策删除——暂停菜单自 v3.2 起离开已是「保存并离开」（不丢进度），
# HUD 直点按钮同步后，「离开」不再是破坏性操作，确认框对玩家只剩打断作用
#（实测反馈：每次离开都弹，很烦）。离开路径现统一为 GameSession.save_now() + 切场景，
# 见 hud.gd / pause_menu.gd；test_ui_confirm.gd 有源码级守卫防止确认框被加回来。
class_name UiConfirm
extends RefCounted

## 开局多少秒内视为「几乎无进展」，跳过二次确认。
const TRIVIAL_SEC := 5.0


## 弹出确认框；确认后回调 on_ok。关闭即自动释放（一次性对象）。
static func ask(parent: Node, text: String, ok_text: String, cancel_text: String,
        on_ok: Callable) -> ConfirmationDialog:
	if parent == null or not parent.is_inside_tree():
		return null
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = text
	dlg.ok_button_text = ok_text
	dlg.cancel_button_text = cancel_text
	dlg.exclusive = true
	parent.add_child(dlg)
	dlg.confirmed.connect(on_ok)
	# 关闭即释放：确认框是一次性对象，留在树里会累积节点。
	# ⚠️ 不能用 popup_hide —— 那是 Popup（PopupPanel）的信号，
	# ConfirmationDialog 走 AcceptDialog → Window，没有它（实测报
	# "Invalid access to property or key 'popup_hide'"）。
	# 这里用 confirmed / canceled / close_requested 三路兜底。
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	if dlg.has_signal("close_requested"):
		dlg.close_requested.connect(dlg.queue_free)
	dlg.popup_centered()
	return dlg


## 重开当前关：R 键与 HUD「重开」共用，保证两处口径一致。
## v3.3：本关有绘画草稿时提示「草稿也会被清除」；「不再提示」勾选后持久化，
## 此后重开直接执行（不再弹任何确认）。
static func confirm_restart(parent: Node, on_ok: Callable) -> void:
	if GameSession.state != GameSession.State.PLAYING or GameSession.elapsed < TRIVIAL_SEC:
		on_ok.call()
		return
	if SettingsManager != null and not SettingsManager.restart_confirm:
		on_ok.call()
		return
	if parent == null or not parent.is_inside_tree():
		on_ok.call()
		return
	var secs := int(GameSession.elapsed)
	var tip := "重开会从头开始本关（当前已用时 %02d:%02d），确定吗？" % [secs / 60, secs % 60]
	if GameSession.has_saved_draft():
		tip += "\n注意：重开后本关的绘画草稿也会被清除。"
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = tip
	dlg.ok_button_text = "确定"
	dlg.cancel_button_text = "取消"
	dlg.exclusive = true
	var chk := CheckBox.new()
	chk.text = "不再提示"
	dlg.add_child(chk)
	parent.add_child(dlg)
	dlg.confirmed.connect(func():
		if chk.button_pressed and SettingsManager != null:
			SettingsManager.set_restart_confirm(false)
		on_ok.call())
	# 关闭即释放（同 ask()：confirmed/canceled/close_requested 三路兜底）
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	if dlg.has_signal("close_requested"):
		dlg.close_requested.connect(dlg.queue_free)
	dlg.popup_centered()
