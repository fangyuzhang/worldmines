extends VariantBase
## 首雷 FR（GDD §3.2.2）：每个格子绑定一个扫描方向（上/下/左/右），
## 显示沿该方向到第一颗雷之间的安全格数；无雷显示 ∞。
## 方向用坐标哈希确定性分配：(r*3 + c*5) % 4 → 0上 1右 2下 3左

func _init() -> void:
	id = "FR"
	display_name = "首雷"
	category = Category.NUMBER_RULE
	difficulty = 3
	compat_score = 9.0
	weight = "light"

const DIRS: Array[Vector2i] = [Vector2i(-1, 0), Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1)]

func _dir_of(r: int, c: int) -> int:
	return (r * 3 + c * 5) % 4

## 沿方向到首雷的安全格数；-1 表示全程无雷（∞）
func _ray(board: Board, r: int, c: int) -> int:
	var d: Vector2i = DIRS[_dir_of(r, c)]
	var nr: int = r + d.x
	var nc: int = c + d.y
	var n := 0
	while board.in_bounds(nr, nc):
		if board.is_mine(nr, nc):
			return n
		n += 1
		nr += d.x
		nc += d.y
	return -1

func compute_clues(board: Board, r: int, c: int) -> Array[VariantClue]:
	if board.is_mine(r, c):
		return []
	var val := _ray(board, r, c)
	var text: String = "∞" if val == -1 else str(val)
	return [VariantClue.new(text, false)]

func is_flood_seed(board: Board, r: int, c: int) -> bool:
	return false

func cell_display(board: Board, r: int, c: int) -> String:
	if board.is_mine(r, c):
		return "💣"
	var val := _ray(board, r, c)
	return "∞" if val == -1 else str(val)
