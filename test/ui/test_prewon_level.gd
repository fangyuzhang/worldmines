# test_prewon_level.gd —— 「开局即终局」盘的双时序回归（真实 bug：全开却无结算的死盘）
#
# 背景：某些关卡的 revealed 覆盖全部非雷格 ⇒ 引擎在 load_level 内即判 WON；
# 而终局覆盖层（game_over）要等 board_view._ready 才实例化并连 game_ended——
# _finish 早已 emit 完毕，信号丢在空处 ⇒ 玩家看到「全开却无结算、点不动」的死盘（重开一样）。
# 本文件锁死两条加载时序（覆盖层先就绪 / 后就绪）都必须能补显结算；修复前两条都红。
extends GutTest

const LEVEL_PATH := "user://test_prewon_level.json"
const SIZE := 5
## 雷位（r,c，自定）：两条对角线 + 边角，共 10 个；剩余 15 个非雷格全部进 revealed。
const MINES: Array = [[0, 0], [1, 1], [2, 2], [3, 3], [4, 4], [0, 4], [4, 0], [2, 0], [0, 2], [4, 2]]

var _progress_backup: String = ""
var _progress_backup_exists: bool = false


func before_all() -> void:
	_write_prewon_level()


func after_all() -> void:
	# 清掉测试关卡文件（user:// 是真实用户目录，不留测试垃圾）
	var d := DirAccess.open("user://")
	if d != null and d.file_exists(LEVEL_PATH.get_file()):
		d.remove(LEVEL_PATH.get_file())


func before_each() -> void:
	# 进度文件是全进程共享的**真实存档**：开局即胜盘会在 _finish 里 record_clear，
	# 不备份还原就等于往玩家存档里塞测试键（与 test_game_over_next 同款防护）。
	_progress_backup = ""
	_progress_backup_exists = FileAccess.file_exists(ProgressStore.PATH)
	if _progress_backup_exists:
		var f := FileAccess.open(ProgressStore.PATH, FileAccess.READ)
		_progress_backup = f.get_as_text()
		f.close()
	ProgressStore.reset_cache()
	# 隔离会话残留（跨文件测试顺序不可控）：否则上一用例的 ENDED 状态会干扰补显断言
	GameSession.state = GameSession.State.IDLE
	GameSession.board = null
	GameSession.level_path = ""
	GameSession.last_result_won = false


func after_each() -> void:
	if _progress_backup_exists:
		var f := FileAccess.open(ProgressStore.PATH, FileAccess.WRITE)
		f.store_string(_progress_backup)
		f.close()
	else:
		var d := DirAccess.open("user://")
		if d != null and d.file_exists("progress.json"):
			d.remove("progress.json")
	ProgressStore.reset_cache()


# 用例 1：覆盖层**先就绪**（先 instantiate、后 start_level——如「重开」路径）。
# 终局信号能被直接收到，但 start_level 末尾的 session_started 仍会触发隐藏
# → 必须靠 _on_hide 的终局分支保显，否则结算刚显示就被抹掉（另一半死盘根因）。
func test_prewon_level_ends_with_win_overlay() -> void:
	var go = load("res://ui/game_over.tscn").instantiate()
	add_child_autofree(go)
	assert_true(GameSession.start_level(LEVEL_PATH), "开局即胜的关卡应能加载")
	assert_eq(GameSession.state, GameSession.State.ENDED, "开局即胜的关卡必须立即进入终局")
	assert_true(go.visible, "终局覆盖层必须可见（否则是死盘）")
	assert_eq(go._big_label.text, "胜利！", "应为胜局文案")


# 用例 2：**复现真实时序**（level_select：先 start_level → 之后才 change_scene 进 board_view，
# 覆盖层在 board_view._ready 里才创建）——game_ended 早已 emit，只能靠 _ready 自同步补显。
# 这条正是本 bug 的守卫；修复前必红。
func test_prewon_level_overlay_syncs_when_created_after_start() -> void:
	assert_true(GameSession.start_level(LEVEL_PATH), "开局即胜的关卡应能加载")
	assert_eq(GameSession.state, GameSession.State.ENDED, "开局即胜的关卡必须立即进入终局")
	assert_true(GameSession.last_result_won, "会话应记录终局结果（覆盖层补显依赖它）")
	var go = load("res://ui/game_over.tscn").instantiate()
	add_child_autofree(go)
	assert_true(go.visible, "覆盖层后创建也必须补显（否则是死盘）")
	assert_eq(go._big_label.text, "胜利！", "应为胜局文案")


func _write_prewon_level() -> void:
	# 5×5 / 10 雷：revealed = 其余全部 15 个非雷格 ⇒ 加载即 unknown(10) == remaining(10) ⇒ 判 WON。
	var mine_set := {}
	var mines: Array = []
	for rc in MINES:
		mines.append({"r": int(rc[0]), "c": int(rc[1])})
		mine_set[Vector2i(int(rc[0]), int(rc[1]))] = true
	var revealed: Array = []
	for r in SIZE:
		for c in SIZE:
			if not mine_set.has(Vector2i(r, c)):
				revealed.append({"r": r, "c": c})
	assert_eq(revealed.size(), SIZE * SIZE - MINES.size(), "revealed 应覆盖全部非雷格（15 个）")
	var doc := {
		"name": "test_prewon_level",
		"size": {"rows": SIZE, "cols": SIZE},
		"total_mines": MINES.size(),
		"mines": mines,
		"revealed": revealed,
		# 这类盘的画像峰值恒 0（无推理步）——正是重标工具要拦下、不让其混进任何玩家档的形态
		"difficulty_profile": {"difficulty": 0.1, "rounds": 1, "max_batch": 10,
			"max_complexity": 0, "histogram": "0x1"},
	}
	var f := FileAccess.open(LEVEL_PATH, FileAccess.WRITE)
	assert_not_null(f, "应能写入测试关卡文件: " + LEVEL_PATH)
	if f == null:
		return
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
