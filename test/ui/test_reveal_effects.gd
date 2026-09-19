# test_reveal_effects.gd —— 「翻开动效」总闸（SettingsManager.ripple_enabled）的存取 / 运行时契约
#
# 语义（team-lead 裁决 2026-09-19）：ripple_enabled 是**唯一的翻开动效开关**，已从
# 「波浪涟漪」扩展为总闸（管波浪 + 后续单格 pop）。界面只允许一行同名开关——本文件
# 除行为断言外，还守护「面板与弹窗各只有一个相关开关行、且标签正确」。
#
# 覆盖（对应交付验收）：
#   ① 默认值：无 cfg 文件时默认开启；
#   ② 持久化往返：setter → 写盘 → 新实例 load_cfg 读回一致；
#   ③ 运行时抑制：关闭后 board_view 的波浪不产生（_ripples 为空）；
#   ④ 无残留：波浪在途时关闭 → 队列/缓存清空、格子 s 回 1.0、线色走原色路径；
#   ⑤ 设置界面：面板 / 弹窗各只有一个「翻开」开关，标签正确且切换即时经 SettingsManager 生效。
#
# 观测手段沿用 test_wave_animation：读 _ripples / _ripple_cache，直接调用带默认参的
# _process/_ripple_rect_for；**不新增/改动任何公开 API**。
#
# 纪律：SettingsManager 是 autoload（全局单例），用例前后必须恢复现场——写回原值并
# 清理 user://settings.cfg（与 test_theme_settings 同口径），避免污染其它测试文件。
extends GutTest

const CFG := "user://settings.cfg"
const SCRIPT := "res://ui/settings_manager.gd"
## 界面唯一开关的最终文案（面板与弹窗必须一致）
const REVEAL_LABEL := "翻开动效（波浪 / 单格）"

## 内存关卡：5×5、仅 (4,4) 有雷 ⇒ (0,0) 值为 0（翻开会整片泛洪）。
const ZERO_LEVEL := {
	"size": {"rows": 5, "cols": 5},
	"total_mines": 1,
	"mines": [{"r": 4, "c": 4}],
	"revealed": [],
}

var _view
var _prev_ripple := true


func before_each() -> void:
	# 清理测试产物，保证「无 cfg → 默认值」用例成立
	_rm(CFG)
	_prev_ripple = SettingsManager.ripple_enabled
	SettingsManager.ripple_enabled = true  # 每个用例从「开」出发，与用户设置解耦
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")


func after_each() -> void:
	# 恢复现场：写回原值 + 抹掉测试写出的 cfg
	SettingsManager.ripple_enabled = _prev_ripple
	_rm(CFG)
	GameSession.start_level("res://levels/classic_01.json")  # 复位全局盘面


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _new_sm() -> Node:
	return (load(SCRIPT) as GDScript).new()


func _make_view() -> void:
	_view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(_view)


## 用内存关卡替换盘面（只设 GameSession.board 并重连视图信号——最小侵入）。
func _install_board(level: Dictionary) -> Board:
	var b := Board.new()
	b.load_level(level)
	GameSession.board = b
	_view._connect_board()
	return b


## 递归收集 root 下全部控件。
func _all_controls(root: Node) -> Array:
	var out: Array = []
	for c in root.get_children():
		out.append(c)
		out.append_array(_all_controls(c))
	return out


## 取 CheckButton 所在行的 Label 文本（_add_check_row 结构：HBox = Label + CheckButton）。
func _row_label_for(chk: Control) -> String:
	var row := chk.get_parent()
	if row == null:
		return ""
	for c in row.get_children():
		if c is Label:
			return (c as Label).text
	return ""


## 统计标签含「翻开」的开关数量（用于断言没有两行重叠开关）。
func _count_reveal_checks(root: Node) -> int:
	var n := 0
	for c in _all_controls(root):
		if c is CheckButton and "翻开" in _row_label_for(c):
			n += 1
	return n


# ---------- ① 默认值 ----------

func test_default_is_on() -> void:
	var sm: Node = _new_sm()
	sm.load_cfg()  # 无 cfg 文件 → 按默认值
	assert_eq(sm.get("ripple_enabled"), true, "未写过设置时「翻开动效」应默认开启")
	sm.free()


# ---------- ② 持久化往返 ----------

func test_setter_persists() -> void:
	var sm: Node = _new_sm()
	sm.load_cfg()
	sm.set_ripple_enabled(false)
	assert_true(FileAccess.file_exists(CFG), "cfg 应已写盘")

	var sm2: Node = _new_sm()
	sm2.load_cfg()
	assert_eq(sm2.get("ripple_enabled"), false, "写盘后新实例应能读回关闭值")
	sm.free()
	sm2.free()


# ---------- ③ 关闭则波浪不产生 ----------

func test_off_suppresses_zero_flood_wave() -> void:
	SettingsManager.set_ripple_enabled(false)
	_make_view()
	var board := _install_board(ZERO_LEVEL)
	var start := Vector2i(0, 0)
	assert_true(board.grid.get_cell(start).is_zero_clue(), "起点应为 0 值格")
	board.reveal(start)  # 0 格泛洪（联动）
	await wait_process_frames(2)
	assert_true(_view._ripples.is_empty(), "关闭总闸后 0 格泛洪不得产生波浪")


# ---------- ④ 关闭则不残留（在途波浪立即归零） ----------

func test_off_clears_inflight_wave_no_residue() -> void:
	_make_view()
	# 总闸开启下起波：中段应有收缩态（s < 1.0），证明波浪确实在动
	_view._start_wave(Vector2i(0, 0))
	assert_false(_view._ripples.is_empty(), "开启时 _start_wave 应建立波浪")
	var rec: Dictionary = _view._ripples[0]
	var t0 := int(rec["t0"])
	_view._rebuild_ripple_cache(t0 + 10)
	var deformed := false
	for p in _view._ripple_cache:
		if float(_view._ripple_cache[p]["s"]) < 1.0:
			deformed = true
			break
	assert_true(deformed, "中段格子应处于收缩态（s < 1.0）")

	# 关掉总闸 → 在途波浪被立刻丢弃，重绘回到静止态
	SettingsManager.set_ripple_enabled(false)
	_view._process(0.0)
	assert_true(_view._ripples.is_empty(), "关闭总闸应清掉在途波浪队列")
	assert_true(_view._ripple_cache.is_empty(), "关闭总闸应清空波浪缓存（线色不再混向高亮）")
	var rest := Rect2(3.0, 4.0, 10.0, 10.0)
	assert_eq(_view._ripple_rect_for(Vector2i(0, 0), rest), rest, "关闭后格子 s 应回到 1.0（返回原矩形）")


# ---------- ⑤ 设置界面：唯一开关 + 标签 + 实时生效 ----------

func test_settings_popup_single_toggle() -> void:
	var popup: PopupPanel = load("res://ui/settings_popup.tscn").instantiate()
	add_child_autofree(popup)
	assert_not_null(popup._ripple_chk, "对局内设置弹窗应有翻开动效开关")
	assert_eq(_row_label_for(popup._ripple_chk), REVEAL_LABEL, "弹窗开关标签应为「翻开动效（波浪 / 单格）」")
	assert_eq(_count_reveal_checks(popup), 1, "弹窗应只有一行翻开动效开关（不得再出现第二行重叠开关）")
	var before: bool = SettingsManager.ripple_enabled
	popup._ripple_chk.button_pressed = not before  # 模拟用户点击（触发 toggled）
	assert_eq(SettingsManager.ripple_enabled, not before, "切换「翻开动效」应立即生效")
	SettingsManager.set_ripple_enabled(before)


func test_settings_panel_single_toggle() -> void:
	var panel: Control = load("res://ui/settings_panel.tscn").instantiate()
	add_child_autofree(panel)
	assert_not_null(panel._ripple_chk, "设置面板应有翻开动效开关")
	assert_eq(_row_label_for(panel._ripple_chk), REVEAL_LABEL, "面板开关标签应为「翻开动效（波浪 / 单格）」")
	assert_eq(_count_reveal_checks(panel), 1, "面板应只有一行翻开动效开关（不得再出现第二行重叠开关）")
	assert_eq(panel._ripple_chk.button_pressed, SettingsManager.ripple_enabled, "开关初值应等于当前设置")
