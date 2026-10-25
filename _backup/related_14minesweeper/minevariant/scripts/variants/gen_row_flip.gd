extends VariantBase
## 行首尾 RF（GDD §3.1.2）：每一行的最左格与最右格的雷状态相反。
## grid[r][0] ≠ grid[r][C-1]。
## A 类生成层约束。

func _init() -> void:
	id = "RF"
	display_name = "行首尾"
	category = Category.GENERATION
	difficulty = 2
	compat_score = 8.0
	weight = "light"

## 与镜像 MX 强冲突（GDD §4.1.3 明确标注为强矛盾对）
func conflict_table() -> Dictionary:
	return { "MX": 10.0, "EP": 1.0 }

func check_constraints(board: Board) -> bool:
	if board.cols < 2:
		return false
	for r in board.rows:
		if board.is_mine(r, 0) == board.is_mine(r, board.cols - 1):
			return false
	return true
