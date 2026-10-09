# test_progress_check.gd —— 试玩期「检查进度（标记插错的旗）」（文档 §7）自证
#
# 钉住四件事：
#   ① 判据（core/progress_check.gd）只认"已插旗且不是雷"的格，盘/网格为空也不崩；
#   ② 界面接线：试玩态下发「检查进度」→ 标记真的落到 board_view 的标记集里，「收起标记」→ 清空；
#   ③ 盘面一变 ⇒ 过期标记自动清掉（留着红叉是**主动误导**，比不标更糟）；
#   ④ **非试玩态一律不标**：对局中判旗的对错 = 泄露雷位，正式游戏里不能靠它作弊。
extends GutTest

const PC := preload("res://core/progress_check.gd")
const CLASSIC := "res://levels/classic_01.json"
const EDITOR_SCENE := "res://ui/level_editor.tscn"


## 造一张 4×4 的盘：mines 给雷位，flags 给"玩家插的旗"。
func _board_with(mines: Array, flags: Array) -> Board:
	var b := Board.new()
	b.load_level({
		"size": {"rows": 4, "cols": 4},
		"total_mines": mines.size(),
		"mines": mines,
		"revealed": [],
	})
	for f in flags:
		b.toggle_flag(f)
	return b


func test_wrong_flags_only_lists_misplaced_flags() -> void:
	var good := Vector2i(1, 1)   # 有雷 ⇒ 插对
	var bad := Vector2i(3, 3)    # 没雷 ⇒ 插错
	var b := _board_with([{"r": 1, "c": 1}], [good, bad])
	var got := PC.wrong_flags(b)
	assert_eq(got.size(), 1, "两格里只有一面旗插错（实际 %s）" % str(got))
	assert_true(got.has(bad), "插错的那一格必须被列出来")
	assert_false(got.has(good), "插对的旗不算错，不许列进去")


func test_wrong_flags_is_safe_on_empty_or_unflagged_boards() -> void:
	assert_eq(PC.wrong_flags(null).size(), 0, "盘为空（null）必须返回空数组，不许崩")
	assert_eq(PC.wrong_flags(Board.new()).size(), 0, "没载入关卡的盘（grid 为空）也返回空")
	var all_right := _board_with([{"r": 0, "c": 0}], [Vector2i(0, 0)])
	assert_eq(PC.wrong_flags(all_right).size(), 0, "全部插对 = 没有错旗")
	var none := _board_with([{"r": 0, "c": 0}], [])
	assert_eq(PC.wrong_flags(none).size(), 0, "一面旗都没插 = 没有错旗")


func test_progress_check_marks_and_clears_through_the_ui() -> void:
	assert_true(GameSession.start_level(CLASSIC), "需要一个真实关卡")
	var prev_return := str(GameSession.playtest_return)
	var view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(view)
	await get_tree().process_frame
	var board: Board = GameSession.board
	# 找一格不是雷的格插旗 —— 就是"插错"
	var bad := Vector2i(-1, -1)
	for p in board.grid.all_positions():
		if not board.is_mine(p):
			bad = p
			break
	assert_ne(bad, Vector2i(-1, -1), "前置：盘上应存在不是雷的格")
	board.toggle_flag(bad)
	await get_tree().process_frame
	# ① 非试玩态：信号发了也不标（正式游戏里这不是作弊入口）
	GameSession.playtest_return = ""
	GameSession.progress_check_requested.emit(true)
	assert_eq((view.get("_wrong_flag_marks") as Array).size(), 0,
		"非试玩态不得标出错旗（对局中判旗对错就是泄露雷位）")
	# ② 试玩态：标出那一格
	GameSession.playtest_return = EDITOR_SCENE
	GameSession.progress_check_requested.emit(true)
	var marks: Array = view.get("_wrong_flag_marks")
	assert_eq(marks.size(), 1, "试玩态应标出 1 面错旗（实际 %s）" % str(marks))
	assert_true(marks.has(bad), "标出来的应正是插错的那一格")
	# ③ 「收起标记」清空
	GameSession.progress_check_requested.emit(false)
	assert_eq((view.get("_wrong_flag_marks") as Array).size(), 0, "「收起标记」应清空标记")
	# ④ 盘面一变 ⇒ 过期标记自动清（红叉留着会误导）
	GameSession.progress_check_requested.emit(true)
	assert_eq((view.get("_wrong_flag_marks") as Array).size(), 1, "重新检查应能再标出来")
	board.toggle_flag(bad)   # 取消那面旗 = 盘面变化
	assert_eq((view.get("_wrong_flag_marks") as Array).size(), 0,
		"盘面一变，过期标记必须自动清掉（否则玩家会照错红叉做判断）")
	GameSession.playtest_return = prev_return
	GameSession.start_level(CLASSIC)   # 复位全局盘面，避免污染后续用例

## 按文字找普通按钮（CheckButton 之类不算：`get_class()` 必须是 Button）。
func _find_text(root: Node, text: String) -> Button:
	for b in root.find_children("*", "Button", true, false):
		var bt := b as Button
		if bt.get_class() == "Button" and bt.text == text:
			return bt
	return null


func test_hud_shows_the_progress_buttons_only_during_playtest() -> void:
	assert_true(GameSession.start_level(CLASSIC), "需要一个真实关卡")
	var prev_return := str(GameSession.playtest_return)
	# ① 正式游戏（`playtest_return` 为空）⇒ 两个按钮都不存在
	GameSession.playtest_return = ""
	var normal: Control = load("res://ui/hud.tscn").instantiate()
	add_child_autofree(normal)
	await get_tree().process_frame
	assert_null(_find_text(normal, "检查进度"), "正式游戏里不得有「检查进度」（对局中判旗对错 = 泄露雷位）")
	assert_null(_find_text(normal, "收起标记"), "正式游戏里不得有「收起标记」")
	# ② 试玩态 ⇒ 两个按钮都在，且按下去真的发请求（文档 §7 的入口）
	GameSession.playtest_return = EDITOR_SCENE
	var play: Control = load("res://ui/hud.tscn").instantiate()
	add_child_autofree(play)
	await get_tree().process_frame
	var chk := _find_text(play, "检查进度")
	assert_not_null(chk, "试玩态应有「检查进度」入口（文档 §7）")
	var clr := _find_text(play, "收起标记")
	assert_not_null(clr, "试玩态应有「收起标记」入口（标记过期要能手动收起）")
	if chk != null:
		var got: Array = []
		GameSession.progress_check_requested.connect(
			func(mark: bool) -> void: got.append(mark), CONNECT_ONE_SHOT)
		(chk as Button).pressed.emit()
		assert_eq(got, [true], "按「检查进度」应发出 mark=true 的请求")
	GameSession.playtest_return = prev_return
