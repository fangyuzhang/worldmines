extends VariantBase
## 局部禁形 PF（GDD §3.1.6）：任何 2×2 方块中雷数 ≤ 2。
## 采用拒绝采样（局部约束，低密度下效率足够）。

func _init() -> void:
	id = "PF"
	display_name = "局部禁形"
	category = Category.GENERATION
	difficulty = 3
	compat_score = 8.0
	weight = "light"

func conflict_table() -> Dictionary:
	return { "CC": 3.0 }

func check_constraints(board: Board) -> bool:
	for r in range(board.rows - 1):
		for c in range(board.cols - 1):
			var cnt := 0
			if board.is_mine(r, c): cnt += 1
			if board.is_mine(r, c + 1): cnt += 1
			if board.is_mine(r + 1, c): cnt += 1
			if board.is_mine(r + 1, c + 1): cnt += 1
			if cnt > 2:
				return false
	return true
