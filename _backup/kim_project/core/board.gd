# board.gd —— 棋盘核心（文档 §3.2/§3.3/§3.4/§4.2）【人工锁死】
# 双视角隔离：求解器/提示器只准通过 get_player_constraint(pos) 获取玩家视角约束。
# 判负唯一入口：is_mine(pos)。get_mine_positions() 注释锁死 P4 语义：返回 _static ∪ _dynamic。
class_name Board
extends RefCounted

enum GameState { PLAYING, WON, LOST }

signal game_won
signal game_lost

var grid: RectGrid = null
var total_mines: int = 0
var state: int = GameState.PLAYING

# 静态雷位（P0 唯一来源）。P4 扩展为 _static ∪ _dynamic，但本字段不更名。
var _static_mines: Array[Vector2i] = []


## 从预置关卡 JSON 构造棋盘。
func load_level(level: Dictionary) -> void:
	state = GameState.PLAYING
	total_mines = level.get("total_mines", 0)
	_static_mines.clear()

	var g: Dictionary = level["grid"]
	var rows: int = g["rows"]
	var cols: int = g["cols"]
	grid = RectGrid.new()
	grid.setup(rows, cols)

	for m in level.get("mines", []):
		_static_mines.append(Vector2i(m[1], m[0]))  # JSON 存 [row, col] → Vector2i(col, row)
		grid.get_cell(Vector2i(m[1], m[0])).is_mine = true

	_compute_clues()

	# ? 格遮蔽区间（hidden 字段：[row, col, [lo, hi]]）
	for h in level.get("hidden", []):
		var cell := grid.get_cell(Vector2i(h[1], h[0]))
		cell.hidden_interval = Vector2i(h[2][0], h[2][1])

	# 初始翻开格（revealed 字段：[[row, col], ...]）
	for r in level.get("revealed", []):
		reveal(Vector2i(r[1], r[0]))


## 计算全盘线索值（8 邻求和，经典规则）。
func _compute_clues() -> void:
	var size := grid.size()
	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var cell := grid.get_cell(pos)
			if cell.is_mine:
				continue
			var n := 0
			for nb in grid.get_neighbors(pos):
				if grid.get_cell(nb).is_mine:
					n += 1
			cell.value = n


## 翻开格子。第一行必须检查 state == PLAYING。
func reveal(pos: Vector2i) -> void:
	if state != GameState.PLAYING:
		return
	if grid == null or not grid.in_board(pos):
		return
	var cell := grid.get_cell(pos)
	if cell.state == Cell.State.REVEALED:
		return
	# 插旗/笔记格的翻开语义：先清除标记（P0 简化：直接翻开）
	if cell.state == Cell.State.FLAGGED or cell.state == Cell.State.QUESTION:
		cell.state = Cell.State.HIDDEN

	if cell.is_mine:
		cell.state = Cell.State.REVEALED
		state = GameState.LOST
		game_lost.emit()
		return

	_flood_reveal(pos)
	_check_win()


## 经典 0 格连锁扩散。
func _flood_reveal(start: Vector2i) -> void:
	var stack: Array[Vector2i] = [start]
	var visited: Array[Vector2i] = []
	while not stack.is_empty():
		var pos: Vector2i = stack.pop_back()
		if visited.has(pos):
			continue
		visited.append(pos)
		var cell := grid.get_cell(pos)
		if cell.state != Cell.State.HIDDEN:
			continue
		cell.state = Cell.State.REVEALED
		# ? 格即使底层为 0 也不扩散（其 interval 约束已进约束集）
		if cell.value == 0 and not cell.is_hidden_clue():
			for nb in grid.get_neighbors(pos):
				var ncell := grid.get_cell(nb)
				if ncell.state == Cell.State.HIDDEN:
					stack.append(nb)


## 插旗/笔记?/取消 循环标记（右键）。
func toggle_flag(pos: Vector2i) -> void:
	if state != GameState.PLAYING:
		return
	if grid == null or not grid.in_board(pos):
		return
	var cell := grid.get_cell(pos)
	if cell.state == Cell.State.REVEALED:
		return
	match cell.state:
		Cell.State.HIDDEN:
			cell.state = Cell.State.FLAGGED
		Cell.State.FLAGGED:
			cell.state = Cell.State.QUESTION
		Cell.State.QUESTION:
			cell.state = Cell.State.HIDDEN


## 【双视角唯一入口】玩家视角约束集。调用方仅限求解器/提示器。
func get_player_constraint(pos: Vector2i) -> Dictionary:
	if grid == null or not grid.in_board(pos):
		return { "type": "none" }
	return grid.get_cell(pos).get_player_constraint()


## 判负唯一入口。P4 注释锁死：返回 _static ∪ _dynamic。
func is_mine(pos: Vector2i) -> bool:
	if grid == null or not grid.in_board(pos):
		return false
	return grid.get_cell(pos).is_mine


## 雷位全集。P4 语义 = _static ∪ _dynamic。
func get_mine_positions() -> Array[Vector2i]:
	return _static_mines.duplicate()


func _check_win() -> void:
	if state != GameState.PLAYING:
		return
	var size := grid.size()
	for r in size.y:
		for c in size.x:
			var cell := grid.get_cell(Vector2i(c, r))
			if not cell.is_mine and cell.state != Cell.State.REVEALED:
				return
	state = GameState.WON
	game_won.emit()


## 统计信息（供 HUD / 统计使用）。
func get_stats() -> Dictionary:
	var size := grid.size()
	var revealed_count := 0
	var flagged_count := 0
	var total_non_mine := size.x * size.y - total_mines
	for r in size.y:
		for c in size.x:
			var cell := grid.get_cell(Vector2i(c, r))
			match cell.state:
				Cell.State.REVEALED:
					revealed_count += 1
				Cell.State.FLAGGED:
					flagged_count += 1
	return {
		"revealed": revealed_count,
		"flagged": flagged_count,
		"total_non_mine": total_non_mine,
		"remaining": total_non_mine - revealed_count,
	}
