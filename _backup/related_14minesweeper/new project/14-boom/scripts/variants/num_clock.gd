extends VariantBase
## 钟点 Clock（GDD §3.2.3）：按顺时针给 8 邻编号（1=上, 2=右上, ... 8=左上），
## 显示第一颗雷所在的位置序号；8 邻全安全显示 0。
## 边界处理：越界位置视为"安全"（非雷），规则统一（GDD 推荐方案）。

const CLOCK_OFFSETS: Array[Vector2i] = [
	Vector2i(-1, 0),  # 1 上
	Vector2i(-1, 1),  # 2 右上
	Vector2i(0, 1),   # 3 右
	Vector2i(1, 1),   # 4 右下
	Vector2i(1, 0),   # 5 下
	Vector2i(1, -1),  # 6 左下
	Vector2i(0, -1),  # 7 左
	Vector2i(-1, -1), # 8 左上
]

func _init() -> void:
	id = "Clock"
	display_name = "钟点"
	category = Category.NUMBER_RULE
	difficulty = 3
	compat_score = 9.0
	weight = "light"

func _clock_value(board: Board, r: int, c: int) -> int:
	for i in 8:
		var off := CLOCK_OFFSETS[i]
		var nr := r + off.x
		var nc := c + off.y
		if board.in_bounds(nr, nc) and board.is_mine(nr, nc):
			return i + 1
	return 0

func compute_clues(board: Board, r: int, c: int) -> Array[VariantClue]:
	if board.is_mine(r, c):
		return []
	var val := _clock_value(board, r, c)
	return [VariantClue.new(str(val), val == 0)]

func is_flood_seed(board: Board, r: int, c: int) -> bool:
	if board.is_mine(r, c):
		return false
	return _clock_value(board, r, c) == 0

func cell_display(board: Board, r: int, c: int) -> String:
	if board.is_mine(r, c):
		return "💣"
	var val := _clock_value(board, r, c)
	return "" if val == 0 else str(val)
