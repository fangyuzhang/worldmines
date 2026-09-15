# test_level_select_interaction.gd —— 选关页交互契约
#
# 覆盖本轮修复中「只能靠运行期断言」的三点：
#   ① 演示预设（MOCK_CLEARED）不得写进真实进度存档；
#   ② 弹窗关闭动画期间不得被重复打开（原实现会叠出第二个弹窗）；
#   ③ 终局页「下一关」交接的焦点意图应被领取并展开对应弹窗。
extends GutTest

var _view


func before_each() -> void:
	_view = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(_view)


func after_each() -> void:
	LevelSequence.take_focus()  # 清掉可能残留的意图，避免污染其它用例


# LS1：主界面节点图可构建（中心 + 7 线索型 + 7 全局约束 + 7 混合档）
func test_ls1_builds_graph() -> void:
	assert_not_null(_view, "选关页应能实例化")
	assert_eq(_view._nodes.size(), _view.MODES.size(), "每个变体一个节点")


# LS2：演示预设只存在于内存 —— 不得污染 user://progress.json
func test_ls2_mock_progress_is_not_persisted() -> void:
	_view._mode_idx = 0          # classic
	_view._size_idx = 0          # 5×5
	# 注意：_view 是 Variant（场景脚本无 class_name），必须显式标注类型，
	# 否则 Godot 4.7 会因无法推断而 Parse Error（交接文档已记录的坑）。
	var key: String = _view._level_key(0)
	var before: bool = ProgressStore.is_cleared(key)
	_view._ensure_mock()
	assert_true(_view._is_cleared(key), "演示预设应在本进程内生效（解锁流程可演示）")
	if not before:
		assert_false(ProgressStore.is_cleared(key),
				"演示预设绝不能写入真实存档（历史 bug：留下永久的假通关成绩）")


# LS3：关闭动画期间禁止重开弹窗
func test_ls3_popup_close_animation_blocks_reopen() -> void:
	_view._open_popup(0)
	assert_ne(_view._mode_idx, -1, "应已打开弹窗")
	_view._close_popup()
	assert_eq(_view._mode_idx, -1, "关闭后模式复位")
	_view._open_popup(1)
	assert_eq(_view._mode_idx, -1, "关闭动画期间不得再开（否则会叠出两个弹窗）")


# LS4：终局页交接的焦点意图 → 自动展开对应变体的弹窗
func test_ls4_pending_focus_opens_matching_popup() -> void:
	LevelSequence.request_focus("classic", 5)
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	assert_eq(v2._mode_idx, 0, "应自动展开 classic 的关卡弹窗")
	assert_not_null(v2._overlay, "弹窗应处于打开状态")
