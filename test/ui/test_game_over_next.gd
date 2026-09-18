# test_game_over_next.gd —— 终局页「下一关」入口
#
# 关卡解锁依赖「通关上一关」，原先胜利后只有「重新开始 / 返回菜单」，
# 玩家每次都得手动退回选关页重走一遍。本测试锁死新增入口的存在性与适用边界。
extends GutTest

## 生成序列里的关卡路径（无需真实文件：终局页只解析路径，不读盘）。
const GEN_LEVEL := "user://gen_levels/classic_5_0.json"

var _go
var _backup: String = ""
var _backup_exists: bool = false


func before_each() -> void:
	# 进度文件是全进程共享的**真实存档**：本文件的用例会写 gen:// 键，
	# 不备份还原就等于往玩家存档里塞测试数据（历史坑：演示预设直写 cleared）。
	_backup = ""
	_backup_exists = FileAccess.file_exists(ProgressStore.PATH)
	if _backup_exists:
		var f := FileAccess.open(ProgressStore.PATH, FileAccess.READ)
		_backup = f.get_as_text()
		f.close()
	ProgressStore.reset_cache()
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	_go = load("res://ui/game_over.tscn").instantiate()
	add_child_autofree(_go)


func after_each() -> void:
	if _backup_exists:
		var f := FileAccess.open(ProgressStore.PATH, FileAccess.WRITE)
		f.store_string(_backup)
		f.close()
	else:
		var d := DirAccess.open("user://")
		if d != null and d.file_exists("progress.json"):
			d.remove("progress.json")
	ProgressStore.reset_cache()


func _button(text: String) -> Button:
	return _find(_go, text)


func _find(n: Node, text: String) -> Button:
	if n is Button and n.text == text:
		return n
	for c in n.get_children():
		var r: Button = _find(c, text)
		if r != null:
			return r
	return null


# G1：终局页应具备「下一关」入口
func test_g1_next_button_exists() -> void:
	assert_not_null(_button("下一关"), "胜利后应能直接进下一关")
	assert_not_null(_button("重新开始"))
	assert_not_null(_button("返回菜单"))


# G2：手工关（res://levels/…）不在生成序列里 → 不显示该入口
func test_g2_hidden_for_manual_level() -> void:
	var btn := _button("下一关")
	assert_not_null(btn)
	_go._on_game_ended(true)
	assert_false(btn.visible, "非 gen 序列关卡没有「下一关」概念")
	assert_true(_button("撤回") != null and not _button("撤回").visible,
			"胜利局不提供撤回")


# G3：失败终局 → 生成关卡给「跳过本关」（可点）；胜利给的是「下一关」，不该同时给跳过
func test_g3_skip_button_only_on_loss() -> void:
	assert_not_null(_button("跳过本关"), "终局页应有「跳过本关」入口")
	GameSession.level_path = GEN_LEVEL
	_go._on_game_ended(false)
	assert_true(_go._skip_btn.visible, "失败 + 存在下一关 → 应显示跳过")
	assert_false(_go._skip_btn.disabled, "有下一关时可点")
	assert_eq(_go._skip_btn.text, "跳过本关")
	_go._on_game_ended(true)
	assert_false(_go._skip_btn.visible, "胜利已有「下一关」，不再给跳过")


# G4：**真·最后一关** = 最大尺寸（9×9）的末关：入口仍显示（置灰 + 说明原因）
# 早先的实现是直接隐藏，实测反馈「按需求该有的按钮凭空不见了」——没出路和没按钮，
# 前者至少告诉了玩家为什么。注意 5×5 的末关**已不是终点**：它接 6×6（见 G7）。
func test_g4_skip_disabled_only_at_very_last_level() -> void:
	var last := "user://gen_levels/classic_%d_%d.json" % [
			int(LevelSequence.SIZES[-1]), LevelSequence.LEVELS_PER_SET - 1]
	GameSession.level_path = last
	assert_false(LevelSequence.has_skip_target(last), "最大尺寸的末关才是真终点")
	_go._on_game_ended(false)
	assert_true(_go._skip_btn.visible, "真末关也应显示该入口")
	assert_true(_go._skip_btn.disabled, "但不可点：没有下一关可跳")
	assert_true(_go._skip_btn.text.contains("最后一关"),
			"并说明原因而不是留个灰按钮：%s" % _go._skip_btn.text)


# G7：跨尺寸推进 —— 5×5 打完接 6×6 第 1 关；按钮把目标尺寸写在脸上
func test_g7_advance_crosses_size() -> void:
	var last5 := "user://gen_levels/classic_5_%d.json" % (LevelSequence.LEVELS_PER_SET - 1)
	assert_eq(LevelSequence.advance_path(last5), "user://gen_levels/classic_6_0.json",
			"5×5 末关的下一关应是 6×6 第 1 关")
	assert_eq(int(LevelSequence.advance(last5).get("size", 0)), 6, "advance 应带下一尺寸")
	GameSession.level_path = last5
	_go._on_game_ended(false)
	assert_false(_go._skip_btn.disabled, "跨尺寸后跳过仍可用（有下一关）")
	# 胜利侧：has_next 要求当前关已通关，先补一笔真实进度（本文件 after_each 会还原）
	ProgressStore.record_clear(LevelSequence.progress_key(last5), 1.0)
	_go._on_game_ended(true)
	assert_true(_go._next_btn.visible, "胜利时「下一关」应指向下一尺寸")
	assert_true(_go._next_btn.text.contains("6×6"),
			"按钮文案标出目标尺寸：%s" % _go._next_btn.text)


# G6：跳过后回头通关 → 目标键已修（见 P9），这里锁「意图带 auto_start」这条链路：
# 终局页不自己生成关卡，而是要求选关页「领到意图后直接开局」，
# 否则玩家点「下一关」只是回到选关页，还得再点一次（实测反馈：这不叫「到下一关」）。
func test_g6_focus_intent_carries_auto_start() -> void:
	LevelSequence.request_focus("4n", 5)
	assert_false(bool(LevelSequence.take_focus().get("auto_start", false)),
			"普通交接默认只翻页，不自动开局")
	LevelSequence.request_focus("4n", 5, true)
	var f := LevelSequence.take_focus()
	assert_true(bool(f.get("auto_start", false)), "「下一关 / 跳过本关」应要求自动开局")
	assert_eq(str(f["mode"]), "4n")
	assert_eq(int(f["size"]), 5)


# G5：跳过 → 记录 skipped（不算通关），且目标指向下一关
func test_g5_skip_records_and_targets_next() -> void:
	var key := LevelSequence.level_key("classic", 5, 0)
	# 存档里可能已有该键的历史记录 → 只比较「跳过前后」的通关状态，不假设初值
	var cleared_before := ProgressStore.is_cleared(key)
	var next_path := LevelSequence.skip_to_next(GEN_LEVEL)
	assert_eq(next_path, "user://gen_levels/classic_5_1.json", "应指向下一关")
	assert_true(ProgressStore.is_skipped(key), "应记录为已跳过")
	assert_eq(ProgressStore.is_cleared(key), cleared_before,
			"跳过不得改变通关状态（跳过 ≠ 通关）")
