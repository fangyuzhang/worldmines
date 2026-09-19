extends GutTest

## 右键标记循环（v3.5 新增设置「右键可标问号」）：
##   · 关闭（产品默认）：标雷 → 取消，两态，不出现 ? ；
##   · 开启：标雷 → ? → 取消，三态。
##
## ⚠️ 最要紧的一条是 test_existing_question_still_clearable_when_disabled：
## 玩家先开着 ? 标了一批问号，然后把设置关掉——此时盘上残留的 ? **必须还能被清掉**。
## 若连 QUESTION→HIDDEN 一起禁用，那些格子就变成右键永远消不掉的死格，
## 而且**不报错、不提示**，玩家只会以为游戏卡了。这是本次改动唯一的静默失败面。

const LEVEL := {
	"size": {"rows": 5, "cols": 5}, "total_mines": 1,
	"mines": [{"r": 4, "c": 4}],
}


func _board() -> Board:
	var b := Board.new()
	b.load_level(LEVEL)
	return b


func test_two_state_cycle_when_question_disabled() -> void:
	var b := _board()
	var p := Vector2i(0, 0)
	b.toggle_flag(p, false)
	assert_eq(b.grid.get_cell(p).state, Cell.State.FLAGGED, "第一下右键应标雷")
	b.toggle_flag(p, false)
	assert_eq(b.grid.get_cell(p).state, Cell.State.HIDDEN, "第二下应直接取消——不应出现 ? 态")


func test_three_state_cycle_when_question_enabled() -> void:
	var b := _board()
	var p := Vector2i(0, 0)
	b.toggle_flag(p, true)
	assert_eq(b.grid.get_cell(p).state, Cell.State.FLAGGED, "第一下应标雷")
	b.toggle_flag(p, true)
	assert_eq(b.grid.get_cell(p).state, Cell.State.QUESTION, "第二下应为 ? ")
	b.toggle_flag(p, true)
	assert_eq(b.grid.get_cell(p).state, Cell.State.HIDDEN, "第三下才取消")


func test_existing_question_still_clearable_when_disabled() -> void:
	var b := _board()
	var p := Vector2i(0, 0)
	b.toggle_flag(p, true)
	b.toggle_flag(p, true)
	assert_eq(b.grid.get_cell(p).state, Cell.State.QUESTION, "前提：已标为问号")

	b.toggle_flag(p, false)   # 玩家随后关掉了设置
	assert_eq(b.grid.get_cell(p).state, Cell.State.HIDDEN,
		"关闭 ? 后，盘上残留的问号仍必须能被右键清掉（否则是永不消失的死格）")


func test_product_default_is_two_state() -> void:
	# core 的默认参数 true 只是为了向后兼容未传参的调用方（如 scenes/main.gd）；
	# 产品默认值由 SettingsManager 决定，必须是「关闭」。
	if SettingsManager == null:
		pending("SettingsManager 不可用（无 autoload 环境）")
		return
	assert_false(SettingsManager.question_mark_enabled,
		"问号三态的产品默认应为关闭：右键只有标雷 / 取消两态")
