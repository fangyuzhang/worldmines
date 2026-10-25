# test_cell_comp.gd —— CellComp 组件行为钩子测试（P4 组件系统）
extends GutTest

const RevealNeighborComp := preload("res://core/reveal_neighbor_comp.gd")


## 翻开带组件格 → 触发 on_reveal → 正交相邻安全格被揭示；对角不受影响；未声明 flag 的组件不响应插旗。
func test_reveal_comp_triggers() -> void:
	var board := Board.new()
	var grid := RectGrid.new()
	grid.setup(3, 3)
	board.grid = grid
	board.total_mines = 1
	board._static_mines = [Vector2i(0, 0)]
	grid.get_cell(Vector2i(0, 0)).is_mine = true
	board._compute_clues()

	# 中心格挂 RevealNeighborComp（只声明 reveal 效果）
	var center := grid.get_cell(Vector2i(1, 1))
	center.comps.append(RevealNeighborComp.new())

	board.reveal(Vector2i(1, 1))

	# 正交相邻安全格被组件揭示
	for p in [Vector2i(1, 0), Vector2i(1, 2), Vector2i(0, 1), Vector2i(2, 1)]:
		assert_eq(grid.get_cell(p).state, Cell.State.REVEALED, "正交相邻格 %s 应被组件揭示" % p)
	# 对角安全格不被揭示（组件只处理正交）
	for p in [Vector2i(2, 0), Vector2i(0, 2), Vector2i(2, 2)]:
		assert_eq(grid.get_cell(p).state, Cell.State.HIDDEN, "对角格 %s 不应被揭示" % p)


## 未声明 flag 效果的组件在插旗时不触发。
func test_flag_comp_not_triggered_without_decl() -> void:
	var board := Board.new()
	var grid := RectGrid.new()
	grid.setup(3, 3)
	board.grid = grid
	board.total_mines = 0
	board._compute_clues()
	var center := grid.get_cell(Vector2i(1, 1))
	center.comps.append(RevealNeighborComp.new())  # 只声明 reveal，无 flag

	board.toggle_flag(Vector2i(1, 1))
	assert_eq(center.state, Cell.State.FLAGGED, "插旗本身应生效")
	# 组件未声明 flag，故不应有额外副作用（此处无崩溃即通过）
	assert_eq(grid.get_cell(Vector2i(1, 0)).state, Cell.State.HIDDEN, "未声明 flag 的组件不应在插旗时揭示相邻格")
