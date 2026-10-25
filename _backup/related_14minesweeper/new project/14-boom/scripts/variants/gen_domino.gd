extends VariantBase
## 骨牌边界 DT（GDD §3.1.5，方案 B）：棋盘按水平骨牌划分（每行相邻两格一对），
## 每块骨牌至多 1 颗雷（不能两格同时是雷）。雷密度由难度控制。

func _init() -> void:
	id = "DT"
	display_name = "骨牌边界"
	category = Category.GENERATION
	difficulty = 3
	compat_score = 8.0
	weight = "light"

## 每块骨牌：[格A, 格B]，水平相邻
func _dominoes(board: Board) -> Array:
	var out: Array = []
	for r in board.rows:
		for c in range(0, board.cols - 1, 2):
			out.append([Vector2i(r, c), Vector2i(r, c + 1)])
	return out

func check_constraints(board: Board) -> bool:
	for d in _dominoes(board):
		var a: Vector2i = d[0]
		var b: Vector2i = d[1]
		if board.is_mine(a.x, a.y) and board.is_mine(b.x, b.y):
			return false
	return true

func place_all_mines(board: Board, mine_count: int, rng: RandomNumberGenerator) -> bool:
	var dominoes := _dominoes(board)
	if mine_count > dominoes.size():
		return false
	# 从所有骨牌中随机选 mine_count 块，每块随机放 1 颗雷
	var pool := dominoes.duplicate()
	var placed := 0
	while placed < mine_count and not pool.is_empty():
		var idx := rng.randi_range(0, pool.size() - 1)
		var d: Array = pool[idx]
		pool.remove_at(idx)
		var p: Vector2i = d[rng.randi_range(0, 1)]
		board.set_mine(p.x, p.y, true)
		placed += 1
	return placed == mine_count
