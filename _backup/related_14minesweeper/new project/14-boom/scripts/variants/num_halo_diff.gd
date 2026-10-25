extends VariantBase
## 环差 HaloDiff（GDD §3.2.6）：数字 = 内环雷数 − 外环雷数。
## 内环 = 切比雪夫距离 1 的 8 邻；外环 = 距离恰为 2 的 16 格。
## 数字可为负。GDD 建议禁用自动洪水填充。

func _init() -> void:
	id = "HaloDiff"
	display_name = "环差"
	category = Category.NUMBER_RULE
	difficulty = 4
	compat_score = 8.0
	weight = "heavy"

func conflict_table() -> Dictionary:
	return { "CC": 2.0 }

func _halo(board: Board, r: int, c: int) -> int:
	var inner := 0
	var outer := 0
	for dr in range(-2, 3):
		for dc in range(-2, 3):
			if dr == 0 and dc == 0:
				continue
			var dist := maxi(abs(dr), abs(dc))
			var nr: int = r + dr
			var nc: int = c + dc
			if not board.in_bounds(nr, nc):
				continue
			if not board.is_mine(nr, nc):
				continue
			if dist == 1:
				inner += 1
			elif dist == 2:
				outer += 1
	return inner - outer

func compute_clues(board: Board, r: int, c: int) -> Array[VariantClue]:
	if board.is_mine(r, c):
		return []
	return [VariantClue.new(str(_halo(board, r, c)), false)]

func is_flood_seed(board: Board, r: int, c: int) -> bool:
	return false

func cell_display(board: Board, r: int, c: int) -> String:
	if board.is_mine(r, c):
		return "💣"
	return str(_halo(board, r, c))
