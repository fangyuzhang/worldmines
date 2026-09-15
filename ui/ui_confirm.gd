# ui_confirm.gd —— 二次确认弹窗统一入口
#
# 背景：HUD 上的「返回 / 返回菜单」与 R 键「重开」都是**立即不可撤销**的破坏性操作，
# 且前两者原本挨在一起（文案只差两个字），误点即丢整局。
# 统一入口保证所有危险操作的确认框外观 / 文案 / 判定口径一致
# （R 键与 HUD 按钮共用同一套「毫无进展就免确认」的规则）。
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


## 对局进行中离开当前局。
static func confirm_leave(parent: Node, on_ok: Callable) -> void:
	if GameSession.state != GameSession.State.PLAYING and GameSession.state != GameSession.State.PAUSED:
		on_ok.call()
		return
	var secs := int(GameSession.elapsed)
	var tip := "当前对局尚未结束（已用时 %02d:%02d）。\n离开将放弃本局进度，确定吗？" % [
			secs / 60, secs % 60]
	ask(parent, tip, "离开", "取消", on_ok)


## 重开当前关：R 键与 HUD「重开」共用，保证两处口径一致。
static func confirm_restart(parent: Node, on_ok: Callable) -> void:
	if GameSession.state != GameSession.State.PLAYING or GameSession.elapsed < TRIVIAL_SEC:
		on_ok.call()
		return
	var secs := int(GameSession.elapsed)
	var tip := "重开会从头开始本关（当前已用时 %02d:%02d），确定吗？" % [secs / 60, secs % 60]
	ask(parent, tip, "重开", "取消", on_ok)
