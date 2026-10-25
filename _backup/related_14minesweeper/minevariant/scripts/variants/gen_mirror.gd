extends VariantBase
## 镜像 MX（GDD §3.1.1）：雷的排布关于棋盘中央竖轴对称。
## grid[r][c] = grid[r][C-1-c]。
## A 类生成层约束：只影响雷怎么放，不影响数字计算。

func _init() -> void:
	id = "MX"
	display_name = "镜像"
	category = Category.GENERATION
	difficulty = 2
	compat_score = 8.0
	weight = "light"

## 与行首尾 RF 强冲突（GDD §4.1.3）：镜像要求两端相同，行首尾要求相反 → 无解
func conflict_table() -> Dictionary:
	return { "RF": 10.0, "EP": 2.0, "Quadrant": 2.0 }

func check_constraints(board: Board) -> bool:
	for r in board.rows:
		for c in board.cols:
			var mirror_c := board.cols - 1 - c
			if board.is_mine(r, c) != board.is_mine(r, mirror_c):
				return false
	return true
