extends GutTest

## 胜负原语化（P6，v2.9.3）验证。
##
## 背景：判胜（board._check_win）与判负（reveal 处 is_mine → LOST）此前硬编码在 board.gd，
## 无法被 Mod 覆盖，也没有独立测试。抽成 WinConditionPlugin 后：
##   - 默认实例行为与抽之前逐字节等价（经典扫雷 GDD R10）；
##   - 自定义模式（无猜教学、生存模式）可替换实现；
##   - 胜负规则首次可独立测试。


## 自定义胜负：翻雷不判负（无猜教学模式）。
class NoLoseWin extends WinConditionPlugin:
	func on_reveal_mine(_board: Board) -> bool:
		return false


## 自定义胜负：任意安全翻开即胜（演示 is_won 可被完全替换）。
class AlwaysWin extends WinConditionPlugin:
	func is_won(_board: Board) -> bool:
		return true


func _make_board(mines: Array[Vector2i]) -> Board:
	var board := Board.new()
	var grid := RectGrid.new()
	grid.setup(3, 3)
	board.grid = grid
	board.total_mines = mines.size()
	board._static_mines = mines.duplicate()
	for m in mines:
		grid.get_cell(m).is_mine = true
	board._compute_clues()
	return board


func test_contract_ids_and_describe() -> void:
	var wc := WinConditionPlugin.new()
	assert_eq(str(wc.get_win_id()), "classic", "默认胜负 id 应为 classic")
	assert_eq(str(wc.get_id()), "classic", "get_id 应代理 get_win_id")
	var d: Dictionary = wc.describe()
	assert_true(d.has("name"), "describe 应含 name")
	assert_true(d.has("rule_text"), "describe 应含 rule_text")
	assert_true(wc.on_reveal_mine(null), "默认翻雷应判负")


func test_default_win_when_all_mines_flagged() -> void:
	var board := _make_board([Vector2i(0, 0)])
	assert_eq(board.win_condition.is_won(board), false, "未插旗前不应判胜")
	board.toggle_flag(Vector2i(0, 0))
	assert_eq(board.win_condition.is_won(board), true, "全部雷插旗后应判胜")


func test_default_win_when_remaining_unknown_equals_remaining_mines() -> void:
	# 1 雷，翻开 8 个非雷格 → 剩 1 未知格 == 1 剩余雷 → 判胜（玩家已推完）
	var board := _make_board([Vector2i(0, 0)])
	for r in 3:
		for c in 3:
			var p := Vector2i(c, r)
			if p != Vector2i(0, 0):
				board.reveal(p)
	assert_eq(board.win_condition.is_won(board), true, "剩余未知格数==剩余雷数应判胜")


func test_default_not_win_when_ambiguous() -> void:
	# 2 雷，只翻开 1 格 → 剩余未知 8、剩余雷 2 → 有二义性，不判胜
	var board := _make_board([Vector2i(0, 0), Vector2i(2, 2)])
	board.reveal(Vector2i(0, 1))
	assert_eq(board.win_condition.is_won(board), false, "仍有二义性时不应判胜")


func test_default_loss_on_mine_reveal() -> void:
	var board := _make_board([Vector2i(0, 0)])
	board.reveal(Vector2i(0, 0))
	assert_eq(board.state, Board.GameState.LOST, "默认翻雷应判负")


func test_custom_no_lose_on_mine_reveal() -> void:
	var board := _make_board([Vector2i(0, 0)])
	board.win_condition = NoLoseWin.new()
	board.reveal(Vector2i(0, 0))
	assert_ne(board.state, Board.GameState.LOST, "自定义「翻雷不判负」应保持非 LOST")


func test_custom_win_condition_is_wired() -> void:
	var board := _make_board([Vector2i(0, 0)])
	board.win_condition = AlwaysWin.new()
	board.reveal(Vector2i(0, 1))  # 安全格
	assert_eq(board.state, Board.GameState.WON, "自定义 is_won 应驱动 board 判胜")
