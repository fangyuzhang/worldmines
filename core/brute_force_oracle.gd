# brute_force_oracle.gd —— 统一穷举裁判（文档 §5.2）
# 完备搜索：回溯 + 约束剪枝 + 总雷数过滤，禁止任何启发式截断（不丢解）。
# 独立性铁律：constraint_check 在独立 AI 会话中生成，prompt 只给规则自然语言定义。
#
# 用法：
#   oracle.query(grid_size, revealed, remaining_mines, check, known_mines)
#   - revealed: { pos: constraint_dict }，constraint_dict 来自 board.get_player_constraint：
#       { "type": "equality", "value": v } 或 { "type": "interval", "lo": a, "hi": b }
#   - remaining_mines: 剩余待分配雷数（= 总雷数 - 已插旗数）
#   - check: 注入约束检查（变体扩展点；经典规则下用内化剪枝，等效且更快）
#   - known_mines: 已确定（已插旗）的雷格，从候选排除
#   - 返回: { pos: "safe" | "mine" | "uncertain" }
#
# 性能：内部用整数索引 + 预计算邻接表 + 数组计数，避免字典与重复邻域构造。
# 剪枝（完备，不丢解）：候选=未翻开格；上限/下限/总量剪枝。
class_name BruteForceOracle
extends RefCounted

const MAX_COMBOS := 2_000_000  # 组合数保护：超过直接返回空，绝不硬算


## 预处理（计数型线索内化剪枝）：建索引、邻接、候选、lo/hi、cand_to_rp、counts 等。
## dirs = 线索窗口方向（默认空 = 8 邻，经典）。4n 传正交、sc 传对角。
## 返回 Dictionary；参数非法/候选不足/组合数超限时返回空 {}。
func _build_prep_classic(grid_size: Vector2i, revealed: Dictionary, remaining_mines: int, known_mines: Array[Vector2i], dirs: Array = [], weights: Array = []) -> Dictionary:
	var cols := grid_size.x
	var rows := grid_size.y
	var n := cols * rows
	if remaining_mines < 0 or remaining_mines > n:
		return {}
	if dirs.is_empty():
		dirs = ClueEngine.ring_dirs()
	if weights.is_empty():
		for _d in dirs:
			weights.append(1)

	var cell_idx := {}
	var idx_cell: Array[Vector2i] = []
	for r in rows:
		for c in cols:
			cell_idx[Vector2i(c, r)] = idx_cell.size()
			idx_cell.append(Vector2i(c, r))

	# neighbors[i] = Array of [neighbor_idx, weight]（加权邻接，供 distsum 等加权线索内化剪枝）
	var neighbors: Array = []
	for i in n:
		var arr: Array = []
		var pos := idx_cell[i]
		for di in dirs.size():
			var d: Vector2i = dirs[di]
			var nx: int = pos.x + d.x
			var ny: int = pos.y + d.y
			if nx >= 0 and nx < cols and ny >= 0 and ny < rows:
				arr.append([cell_idx[Vector2i(nx, ny)], weights[di]])
		neighbors.append(arr)

	var known_idx := {}
	for km in known_mines:
		known_idx[cell_idx[km]] = true
	var candidates: Array[int] = []
	for i in n:
		if not revealed.has(idx_cell[i]) and not known_idx.has(i):
			candidates.append(i)
	if candidates.size() < remaining_mines:
		return {}

	var combo_count := _combination_count(candidates.size(), remaining_mines)
	if combo_count > MAX_COMBOS:
		push_warning("BruteForceOracle: 组合数 %d 超保护上限 %d" % [combo_count, MAX_COMBOS])
		return {}

	var revealed_list: Array[int] = []
	var lo: Array[int] = []
	var hi: Array[int] = []
	for pos in revealed:
		var c: Dictionary = revealed[pos]
		revealed_list.append(cell_idx[pos])
		match c.get("type", ""):
			"equality":
				lo.append(c["value"])
				hi.append(c["value"])
			"interval":
				lo.append(c["lo"])
				hi.append(c["hi"])
			_:
				lo.append(-999)
				hi.append(999)

	var cand_to_rp: Array = []
	var rp_to_cand: Array = []
	for j in revealed_list.size():
		rp_to_cand.append([])
	var cand_index := {}
	for j in candidates.size():
		cand_index[candidates[j]] = j
		var hits: Array = []
		for nb_entry in neighbors[candidates[j]]:
			var nb: int = nb_entry[0]
			if revealed.has(idx_cell[nb]):
				var rp_pos := revealed_list.find(nb)
				if rp_pos >= 0:
					hits.append([rp_pos, nb_entry[1]])
					rp_to_cand[rp_pos].append(j)
		cand_to_rp.append(hits)

	var counts: Array[int] = []
	var remaining_nb: Array[int] = []
	for j in revealed_list.size():
		var base := 0
		for nb_entry in neighbors[revealed_list[j]]:
			if known_idx.has(nb_entry[0]):
				base += nb_entry[1]
		counts.append(base)
		# remaining_nb = 该 revealed 格所有剩余候选邻格的权重和
		var rem := 0
		for cj in rp_to_cand[j]:
			for h in cand_to_rp[cj]:
				if h[0] == j:
					rem += h[1]
					break
		remaining_nb.append(rem)

	return {
		"n": n,
		"cell_idx": cell_idx,
		"idx_cell": idx_cell,
		"known_idx": known_idx,
		"candidates": candidates,
		"cand_index": cand_index,
		"revealed_list": revealed_list,
		"lo": lo,
		"hi": hi,
		"cand_to_rp": cand_to_rp,
		"rp_to_cand": rp_to_cand,
		"counts": counts,
		"remaining_nb": remaining_nb,
	}


func query(
	grid_size: Vector2i,
	revealed: Dictionary,
	remaining_mines: int,
	_check: Callable,
	known_mines: Array[Vector2i] = [],
	dirs: Array = [],
	constraint: int = -1,
	dominoes: Array = [],
	weights: Array = [],
	constraint2: int = -1
) -> Dictionary:
	var prep := _build_prep_classic(grid_size, revealed, remaining_mines, known_mines, dirs, weights)
	if prep.is_empty():
		return {}

	# 全局约束叶子检查（闭包捕获预处理数据），与 count_solutions_classic 同构；constraint2 为双布局第二约束。
	var leaf_check := Callable()
	if constraint >= 0 or constraint2 >= 0:
		# 块内副本用 _l 后缀——函数尾部还有同名 idx_cell / combo（父作用域），
		# 同名会让分析器报 CONFUSABLE_LOCAL_DECLARATION（闭包捕获的是本块副本）。
		var idx_cell_l: Array = prep["idx_cell"]
		var cands: Array = prep["candidates"]
		var km: Array = known_mines
		var cst: int = constraint
		var cst2: int = constraint2
		var dom: Array = dominoes
		var gs: Vector2i = grid_size
		leaf_check = func(combo_l: Array) -> bool:
			var mine_set := {}
			for p in km:
				mine_set[p] = true
			for ci in combo_l:
				var pos: Vector2i = idx_cell_l[cands[ci]]
				mine_set[pos] = true
			var extra := {"dominoes": dom}
			if cst >= 0 and not ConstraintEngine.check(cst, mine_set, gs, extra):
				return false
			if cst2 >= 0 and not ConstraintEngine.check(cst2, mine_set, gs, extra):
				return false
			return true

	var solutions: Array = []
	var combo: Array[int] = []
	_backtrack(prep["candidates"], remaining_mines, 0, combo, prep["counts"], prep["remaining_nb"],
		prep["lo"], prep["hi"], prep["cand_to_rp"], solutions, -1, leaf_check)

	var result := {}
	if solutions.is_empty():
		return result
	var n: int = prep["n"]
	var idx_cell: Array = prep["idx_cell"]
	var known_idx: Dictionary = prep["known_idx"]
	var cand_index: Dictionary = prep["cand_index"]
	for i in n:
		var pos: Vector2i = idx_cell[i]
		if revealed.has(pos):
			result[pos] = "safe"
			continue
		if known_idx.has(i):
			result[pos] = "mine"
			continue
		if not cand_index.has(i):
			result[pos] = "uncertain"
			continue
		var ci: int = cand_index[i]
		var mine_in_all := true
		var safe_in_all := true
		for sol in solutions:
			if sol.has(ci):
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


func _backtrack(
	candidates: Array[int],
	k: int,
	idx: int,
	combo: Array[int],
	counts: Array[int],
	remaining_nb: Array[int],
	lo: Array[int],
	hi: Array[int],
	cand_to_rp: Array,
	solutions: Array,
	max_count: int = -1,
	leaf_check: Callable = Callable()
) -> void:
	if max_count > 0 and solutions.size() >= max_count:
		return
	var remaining_cells := candidates.size() - idx
	var remaining_mines := k - combo.size()
	if remaining_cells < remaining_mines:
		return
	if combo.size() == k:
		if _counts_satisfy(counts, lo, hi):
			if leaf_check.is_valid() and not leaf_check.call(combo):
				return
			solutions.append(combo.duplicate())
		return
	if remaining_cells == remaining_mines:
		var full_combo: Array[int] = combo.duplicate()
		for i in range(idx, candidates.size()):
			full_combo.append(i)  # 存候选下标，与 combo 语义一致
		if _counts_plus_nb_satisfy(counts, remaining_nb, lo, hi):
			if leaf_check.is_valid() and not leaf_check.call(full_combo):
				return
			solutions.append(full_combo)
		return

	var hits: Array = cand_to_rp[idx]  # 元素为 [rp, weight]

	# 分支1：不放雷
	for h in hits:
		remaining_nb[h[0]] -= h[1]
	var feasible := true
	for h in hits:
		if counts[h[0]] + remaining_nb[h[0]] < lo[h[0]]:
			feasible = false
	if feasible:
		_backtrack(candidates, k, idx + 1, combo, counts, remaining_nb, lo, hi, cand_to_rp, solutions, max_count, leaf_check)
	for h in hits:
		remaining_nb[h[0]] += h[1]

	# 分支2：放雷
	combo.append(idx)
	for h in hits:
		counts[h[0]] += h[1]
		remaining_nb[h[0]] -= h[1]
	feasible = true
	for h in hits:
		if counts[h[0]] > hi[h[0]] or counts[h[0]] + remaining_nb[h[0]] < lo[h[0]]:
			feasible = false
	if feasible:
		_backtrack(candidates, k, idx + 1, combo, counts, remaining_nb, lo, hi, cand_to_rp, solutions, max_count, leaf_check)
	combo.pop_back()
	for h in hits:
		counts[h[0]] -= h[1]
		remaining_nb[h[0]] += h[1]


## 经典线索（可选全局约束）的唯一解计数。内化剪枝 + 全局约束叶子检查 + max_count 提前终止。
## 返回 1 = 唯一解，>=2 = 多解，0 = 无解（矛盾），-1 = 超限无法判定。
func count_solutions_classic(
	grid_size: Vector2i,
	revealed: Dictionary,
	remaining_mines: int,
	constraint: int = -1,
	dominoes: Array = [],
	known_mines: Array[Vector2i] = [],
	max_count: int = 2,
	dirs: Array = [],
	weights: Array = [],
	constraint2: int = -1
) -> int:
	var n := grid_size.x * grid_size.y
	var cand_count := n - revealed.size() - known_mines.size()
	if remaining_mines < 0 or remaining_mines > n or cand_count < remaining_mines:
		return 0
	if _combination_count(cand_count, remaining_mines) > MAX_COMBOS:
		return -1

	var prep := _build_prep_classic(grid_size, revealed, remaining_mines, known_mines, dirs, weights)
	if prep.is_empty():
		return 0

	# 全局约束叶子检查（闭包捕获预处理数据）；constraint2 为双布局第二约束。
	var leaf_check := Callable()
	if constraint >= 0 or constraint2 >= 0:
		# 块内副本用 _l 后缀——函数尾部还有同名 idx_cell / combo（父作用域），
		# 同名会让分析器报 CONFUSABLE_LOCAL_DECLARATION（闭包捕获的是本块副本）。
		var idx_cell_l: Array = prep["idx_cell"]
		var cands: Array = prep["candidates"]
		var km: Array = known_mines
		var cst: int = constraint
		var cst2: int = constraint2
		var dom: Array = dominoes
		var gs: Vector2i = grid_size
		leaf_check = func(combo_l: Array) -> bool:
			var mine_set := {}
			for p in km:
				mine_set[p] = true
			for ci in combo_l:
				var pos: Vector2i = idx_cell_l[cands[ci]]
				mine_set[pos] = true
			var extra := {"dominoes": dom}
			if cst >= 0 and not ConstraintEngine.check(cst, mine_set, gs, extra):
				return false
			if cst2 >= 0 and not ConstraintEngine.check(cst2, mine_set, gs, extra):
				return false
			return true

	var solutions: Array = []
	var combo: Array[int] = []
	_backtrack(prep["candidates"], remaining_mines, 0, combo, prep["counts"], prep["remaining_nb"],
		prep["lo"], prep["hi"], prep["cand_to_rp"], solutions, max_count, leaf_check)
	return solutions.size()


## 通用变体查询：回溯 + 总量剪枝 + 叶子 check 回调验证。
## check: Callable(mine_set: Array[Vector2i], revealed: Dictionary, grid_size: Vector2i) -> bool
## 适用于 HV/FR/Clock/全局约束等无法用 lo/hi 内化剪枝的变体。
func query_variant(
	grid_size: Vector2i,
	revealed: Dictionary,
	remaining_mines: int,
	check: Callable,
	known_mines: Array[Vector2i] = []
) -> Dictionary:
	var cols := grid_size.x
	var rows := grid_size.y
	var n := cols * rows
	if remaining_mines < 0 or remaining_mines > n:
		return {}

	var all_cells: Array[Vector2i] = []
	for r in rows:
		for c in cols:
			all_cells.append(Vector2i(c, r))

	var candidates: Array[Vector2i] = []
	for pos in all_cells:
		if not revealed.has(pos) and not known_mines.has(pos):
			candidates.append(pos)
	if candidates.size() < remaining_mines:
		return {}

	var combo_count := _combination_count(candidates.size(), remaining_mines)
	if combo_count > MAX_COMBOS:
		push_warning("BruteForceOracle: 组合数 %d 超保护上限，返回空" % combo_count)
		return {}

	var solutions: Array = []
	var combo: Array[Vector2i] = []
	_backtrack_variant(candidates, remaining_mines, 0, combo, check, revealed, grid_size, known_mines, solutions)

	var result := {}
	if solutions.is_empty():
		return result
	for pos in all_cells:
		if revealed.has(pos):
			result[pos] = "safe"
			continue
		if known_mines.has(pos):
			result[pos] = "mine"
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


## 统计满足约束的解数（变体回溯 + check 回调）。max_count 提前终止。
## 用于唯一解校验：返回 1 = 唯一解，>=2 = 多解，0 = 无解（矛盾），-1 = 超限无法判定。
func count_solutions_variant(
	grid_size: Vector2i,
	revealed: Dictionary,
	remaining_mines: int,
	check: Callable,
	known_mines: Array[Vector2i] = [],
	max_count: int = 2
) -> int:
	var cols := grid_size.x
	var rows := grid_size.y
	var n := cols * rows
	if remaining_mines < 0 or remaining_mines > n:
		return 0

	var all_cells: Array[Vector2i] = []
	for r in rows:
		for c in cols:
			all_cells.append(Vector2i(c, r))

	var candidates: Array[Vector2i] = []
	for pos in all_cells:
		if not revealed.has(pos) and not known_mines.has(pos):
			candidates.append(pos)
	if candidates.size() < remaining_mines:
		return 0

	var combo_count := _combination_count(candidates.size(), remaining_mines)
	if combo_count > MAX_COMBOS:
		push_warning("BruteForceOracle: count_solutions 组合数 %d 超保护上限，返回 -1" % combo_count)
		return -1

	var solutions: Array = []
	var combo: Array[Vector2i] = []
	_backtrack_variant(candidates, remaining_mines, 0, combo, check, revealed, grid_size, known_mines, solutions, max_count)
	return solutions.size()


func _backtrack_variant(
	candidates: Array[Vector2i],
	k: int,
	idx: int,
	combo: Array[Vector2i],
	check: Callable,
	revealed: Dictionary,
	grid_size: Vector2i,
	known_mines: Array[Vector2i],
	solutions: Array,
	max_count: int = -1
) -> void:
	if max_count > 0 and solutions.size() >= max_count:
		return
	var remaining_cells := candidates.size() - idx
	var remaining_mines := k - combo.size()
	if remaining_cells < remaining_mines:
		return
	if combo.size() == k:
		var full: Array[Vector2i] = known_mines.duplicate()
		for p in combo:
			if not full.has(p):
				full.append(p)
		if check.call(full, revealed, grid_size):
			solutions.append(combo.duplicate())
		return
	if remaining_cells == remaining_mines:
		var full_combo: Array[Vector2i] = combo.duplicate()
		for i in range(idx, candidates.size()):
			full_combo.append(candidates[i])
		var full: Array[Vector2i] = known_mines.duplicate()
		for p in full_combo:
			if not full.has(p):
				full.append(p)
		if check.call(full, revealed, grid_size):
			solutions.append(full_combo)
		return
	# 分支1：不放雷
	_backtrack_variant(candidates, k, idx + 1, combo, check, revealed, grid_size, known_mines, solutions)
	# 分支2：放雷
	combo.append(candidates[idx])
	_backtrack_variant(candidates, k, idx + 1, combo, check, revealed, grid_size, known_mines, solutions)
	combo.pop_back()


func _counts_satisfy(counts: Array[int], lo: Array[int], hi: Array[int]) -> bool:
	for i in counts.size():
		if counts[i] < lo[i] or counts[i] > hi[i]:
			return false
	return true


func _counts_plus_nb_satisfy(counts: Array[int], remaining_nb: Array[int], lo: Array[int], hi: Array[int]) -> bool:
	for i in counts.size():
		var final := counts[i] + remaining_nb[i]
		if final < lo[i] or final > hi[i]:
			return false
	return true


func _combination_count(n: int, k: int) -> int:
	if k < 0 or k > n:
		return 0
	var kk := mini(k, n - k)
	var result := 1
	for i in range(kk):
		result = result * (n - i) / (i + 1)
		if result > MAX_COMBOS:
			return result
	return int(result)
