# rect_grid.gd —— 矩形网格实现（文档 §3.5）
# 二维数组 Array[Array[Cell]]，8 邻域 + 边界检查。P0 唯一 GridInterface 实现。
class_name RectGrid
extends GridInterface

var _cells: Array = []   # Array[Array[Cell]]
var _rows: int = 0
var _cols: int = 0


func setup(rows: int, cols: int) -> void:
	_rows = rows
	_cols = cols
	_cells.clear()
	for r in rows:
		var row: Array = []
		for c in cols:
			row.append(Cell.new())
		_cells.append(row)


func in_board(pos: Vector2i) -> bool:
	return pos.y >= 0 and pos.y < _rows and pos.x >= 0 and pos.x < _cols


func get_cell(pos: Vector2i) -> Cell:
	if not in_board(pos):
		return null
	return _cells[pos.y][pos.x]


func get_neighbors(pos: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not in_board(pos):
		return out
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var n := Vector2i(pos.x + dx, pos.y + dy)
			if in_board(n):
				out.append(n)
	return out


func size() -> Vector2i:
	return Vector2i(_cols, _rows)
