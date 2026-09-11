# test_levels_solvable.gd —— 关卡纯逻辑可解（文档 §4.4 / §5.2）
# 完美玩家模拟：逐轮查 Oracle（带总雷数/剩余雷数计数器），
# 每步必须存在可确定的必安全格或必雷格，卡死即关卡失败。
# 这是 P0 验收核心：所有预置关卡必须纯逻辑可解。
extends GutTest

const LEVEL_IDS := ["classic_01", "classic_02", "classic_03", "classic_04", "classic_05", "classic_06", "classic_07", "classic_08", "classic_09", "classic_10"]

var _oracle := BruteForceOracle.new()


func _load_level(id: String) -> Dictionary:
	var f := FileAccess.open("res://levels/%s.json" % id, FileAccess.READ)
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return data


## 收集当前玩家视角约束集：已翻开格 -> constraint_dict。
func _collect_revealed(board: Board) -> Dictionary:
	var revealed := {}
	var gsize := board.grid.size()
	for r in gsize.y:
		for c in gsize.x:
			var pos := Vector2i(c, r)
			var cell := board.grid.get_cell(pos)
			if cell.state == Cell.State.REVEALED:
				revealed[pos] = board.get_player_constraint(pos)
	return revealed


## 完美玩家模拟。返回 [是否可解, 步数]。
func _perfect_player(board: Board) -> Array:
	var gsize := board.grid.size()
	var total := board.total_mines
	var known_mines: Array[Vector2i] = []
	var steps := 0

	while true:
		if board.state == Board.GameState.WON:
			return [true, steps]
		if board.state == Board.GameState.LOST:
			return [false, steps]
		if steps > gsize.x * gsize.y * 12:
			return [false, steps]

		var revealed := _collect_revealed(board)
		var remaining := total - known_mines.size()
		var verdict := _oracle.query(gsize, revealed, remaining, ClassicConstraint.check, known_mines)

		# 必安全格（非雷且未翻开）
		var safe: Array[Vector2i] = []
		for r in gsize.y:
			for c in gsize.x:
				var pos := Vector2i(c, r)
				var cell := board.grid.get_cell(pos)
				if cell.state != Cell.State.REVEALED and not board.is_mine(pos):
					if verdict.get(pos) == "safe":
						safe.append(pos)
		# 必雷格（尚未插旗）
		var mine: Array[Vector2i] = []
		for m in board.get_mine_positions():
			if not known_mines.has(m) and verdict.get(m) == "mine":
				mine.append(m)

		if safe.is_empty() and mine.is_empty():
			return [false, steps]  # 卡死：无必安全格且无必雷格

		for p in safe:
			board.reveal(p)
		for m in mine:
			known_mines.append(m)
		steps += 1
	return [false, steps]  # 不可达，满足编译器


func test_all_levels_solvable() -> void:
	for id in LEVEL_IDS:
		var data := _load_level(id)
		var board := Board.new()
		board.load_level(data)
		var result := _perfect_player(board)
		assert_true(result[0], "%s 应纯逻辑可解（步数=%d）" % [id, result[1]])
