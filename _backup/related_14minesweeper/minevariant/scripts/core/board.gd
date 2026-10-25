class_name Board
extends RefCounted
## 棋盘数据模型：格子的雷/状态。不关心变体规则，只提供基础查询。

var rows: int
var cols: int
var cells: Array = []  # 2D Array[Cell]

func _init(p_rows: int, p_cols: int) -> void:
	rows = p_rows
	cols = p_cols
	for r in rows:
		var row: Array[Cell] = []
		for c in cols:
			row.append(Cell.new())
		cells.append(row)

func in_bounds(r: int, c: int) -> bool:
	return r >= 0 and r < rows and c >= 0 and c < cols

func cell(r: int, c: int) -> Cell:
	return cells[r][c]

func is_mine(r: int, c: int) -> bool:
	return cells[r][c].is_mine

func set_mine(r: int, c: int, val: bool) -> void:
	cells[r][c].is_mine = val

func count_mines() -> int:
	var n := 0
	for r in rows:
		for c in cols:
			if cells[r][c].is_mine:
				n += 1
	return n

## 8 邻偏移
const NEIGHBOR8: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(-1, 1),
	Vector2i(0, -1), Vector2i(0, 1),
	Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
]

## 4 邻偏移
const NEIGHBOR4: Array[Vector2i] = [
	Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
]

## 遍历 8 邻中在界内的邻居坐标
func neighbor8_coords(r: int, c: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for off in NEIGHBOR8:
		var nr: int = r + off.x
		var nc: int = c + off.y
		if in_bounds(nr, nc):
			out.append(Vector2i(nr, nc))
	return out

## 遍历 4 邻中在界内的邻居坐标
func neighbor4_coords(r: int, c: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for off in NEIGHBOR4:
		var nr: int = r + off.x
		var nc: int = c + off.y
		if in_bounds(nr, nc):
			out.append(Vector2i(nr, nc))
	return out

## 8 邻雷数（经典扫雷）
func adjacent_mines(r: int, c: int) -> int:
	var n := 0
	for nb in neighbor8_coords(r, c):
		if cells[nb.x][nb.y].is_mine:
			n += 1
	return n
