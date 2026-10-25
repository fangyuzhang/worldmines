# brute_force_oracle.gd —— 统一穷举裁判（文档 §5.2）
# 枚举所有雷分布（组合数，带 total_mines 过滤），对每个分布用注入的 constraint_check 验证。
# 完备搜索，禁止任何启发式截断。独立性铁律：constraint_check 在独立 AI 会话中生成。
#
# 用法：
#   oracle.query(grid_size, revealed, total_mines, check)
#   - revealed: { pos: player_constraint_dict }，来自 board.get_player_constraint
#   - check: Callable(mine_set: Array[Vector2i], revealed: Dictionary, grid_size: Vector2i) -> bool
#   - 返回: { pos: "safe" | "mine" | "uncertain" }
class_name BruteForceOracle
extends RefCounted

const MAX_ENUM_CELLS := 20  # 保护：超过 20 格禁止全枚举（否则组合爆炸）


func query(
	grid_size: Vector2i,
	revealed: Dictionary,
	total_mines: int,
	check: Callable
) -> Dictionary:
	var n := grid_size.x * grid_size.y
	if n > MAX_ENUM_CELLS:
		push_warning("BruteForceOracle: 盘面 %d 格超过保护上限 %d，返回空" % [n, MAX_ENUM_CELLS])
		return {}
	if total_mines < 0 or total_mines > n:
		return {}

	# 关键剪枝：雷位候选只可能是未翻开格（已翻开格必非雷）
	var all_cells := _all_cells(grid_size)
	var cells: Array[Vector2i] = []
	for pos in all_cells:
		if not revealed.has(pos):
			cells.append(pos)
	if cells.size() < total_mines:
		return {}

	var solutions: Array[Array] = []
	var combo: Array[Vector2i] = []
	_combine(cells, total_mines, 0, combo, revealed, check, grid_size, solutions)

	var result := {}
	if solutions.is_empty():
		return result

	for pos in all_cells:
		if revealed.has(pos):
			result[pos] = "safe"  # 已翻开格必非雷
			continue
		var mine_in_all := true
		var safe_in_all := true
		for sol in solutions:
			if sol.has(pos):
				safe_in_all = false
			else:
				mine_in_all = false
			if not mine_in_all and not safe_in_all:
				break
		if mine_in_all:
			result[pos] = "mine"
		elif safe_in_all:
			result[pos] = "safe"
		else:
			result[pos] = "uncertain"
	return result


func _all_cells(grid_size: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for r in grid_size.y:
		for c in grid_size.x:
			out.append(Vector2i(c, r))
	return out


func _combine(
	cells: Array[Vector2i],
	k: int,
	start: int,
	combo: Array[Vector2i],
	revealed: Dictionary,
	check: Callable,
	grid_size: Vector2i,
	solutions: Array[Array]
) -> void:
	if combo.size() == k:
		if check.call(combo.duplicate(), revealed, grid_size):
			solutions.append(combo.duplicate())
		return
	for i in range(start, cells.size()):
		combo.append(cells[i])
		_combine(cells, k, i + 1, combo, revealed, check, grid_size, solutions)
		combo.pop_back()
