# reveal_neighbor_comp.gd —— 示例组件（P4 组件行为系统演示）
# 行为：翻开时自动揭示正交相邻的隐藏安全格（一层，直接置 REVEALED 不递归）。
# 说明：CellComp 的 on_reveal 是 mod 可扩展的行为钩子；effectDecl 声明 reveal 效果后，
#       Board 在 reveal 后调用本组件。此处为内置示例，mod 可注册同类组件扩展玩法。
class_name RevealNeighborComp
extends CellComp

func describe() -> String:
	return "翻开时揭示正交相邻的安全格"


func effectDecl() -> Dictionary:
	return {"reveal": true}


func on_reveal(cell: Cell, board: Board) -> void:
	var pos := _find_pos(board, cell)
	if pos == Vector2i(-1, -1):
		return
	for d in ClueEngine.orthogonal_dirs():
		var p := pos + d
		if not board.grid.in_board(p):
			continue
		var ncell := board.grid.get_cell(p)
		if ncell.state == Cell.State.HIDDEN and not ncell.is_mine:
			ncell.state = Cell.State.REVEALED
			board.cell_state_changed.emit(p)


func _find_pos(board: Board, cell: Cell) -> Vector2i:
	var size := board.grid.size()
	for r in size.y:
		for c in size.x:
			if board.grid.get_cell(Vector2i(c, r)) == cell:
				return Vector2i(c, r)
	return Vector2i(-1, -1)
