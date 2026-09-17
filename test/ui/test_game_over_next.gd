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


# G3：失败终局 → 生成关卡给「跳过本关」；胜利给的是「下一关」，不该同时给跳过
func test_g3_skip_button_only_on_loss() -> void:
	var btn := _button("跳过本关")
	assert_not_null(btn, "终局页应有「跳过本关」入口")
	GameSession.level_path = GEN_LEVEL
	_go._on_game_ended(false)
	assert_true(btn.visible, "失败 + 存在下一关 → 应显示跳过")
	_go._on_game_ended(true)
	assert_false(btn.visible, "胜利已有「下一关」，不再给跳过")


# G4：最后一关失败 → 没有下一关可跳（跳过无处可去，按钮必须隐藏）
func test_g4_skip_hidden_on_last_level() -> void:
	var last := "user://gen_levels/classic_5_%d.json" % (LevelSequence.LEVELS_PER_SET - 1)
	GameSession.level_path = last
	assert_false(LevelSequence.has_skip_target(last), "最后一关无跳过目标")
	_go._on_game_ended(false)
	assert_false(_button("跳过本关").visible, "无下一关时不得显示跳过")


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
