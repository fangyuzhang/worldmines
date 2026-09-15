# test_level_select_focus.gd —— 终局「下一关」→ 选关页 的焦点交接
#
# game_over 不知道下一关怎么生成，只交接「翻到哪一套」的意图；
# 选关页 _ready 领取意图并自动展开弹窗。这条链断了，玩家点「下一关」就只是回到空页面。
extends GutTest

# MODES 顺序（与 ui/level_select.gd 一致）：classic, 4n, clock, hv, fr, loopruns, distsum, sc, ...
const SC_IDX := 7
# SIZES = [5, 6, 7, 8, 9] → 7 的索引是 2
const SIZE7_IDX := 2


func before_each() -> void:
	LevelSequence.take_focus()  # 清理可能残留的交接意图


func after_each() -> void:
	LevelSequence.take_focus()


func test_focus_opens_popup_for_requested_mode() -> void:
	LevelSequence.request_focus("sc", 7)
	# 注意：不能写 var ls := ...（Godot 4.7 对 load().instantiate() 无法推断类型，见坑表 #18）
	var ls = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(ls)

	assert_eq(ls._mode_idx, SC_IDX, "应自动展开「同色 sc」的关卡弹窗")
	assert_eq(ls._size_idx, SIZE7_IDX, "尺寸应切到请求值 7×7")
	assert_not_null(ls._overlay, "弹窗应已打开而不是停在节点图")


func test_no_focus_means_no_popup() -> void:
	# 注意：不能写 var ls := ...（Godot 4.7 对 load().instantiate() 无法推断类型，见坑表 #18）
	var ls = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(ls)
	assert_null(ls._overlay, "没有交接意图时不应自动展开弹窗")
	assert_eq(ls._mode_idx, -1, "未打开弹窗时模式索引应为 -1")


func test_unknown_mode_focus_is_ignored() -> void:
	LevelSequence.request_focus("__mode_that_does_not_exist__", 6)
	# 注意：不能写 var ls := ...（Godot 4.7 对 load().instantiate() 无法推断类型，见坑表 #18）
	var ls = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(ls)
	assert_eq(ls._mode_idx, -1, "未知变体 id 应被忽略而不是越界")
