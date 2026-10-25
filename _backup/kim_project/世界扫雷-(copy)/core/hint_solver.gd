# hint_solver.gd —— 提示求解器（文档 §6.1 / §6.2）
# 基于玩家视角约束，产出一歩直推的推理链。
# 每个 ReasoningStep：结论格 + 状态 + 依据线索格 + 推理文字。
# 只做 100% 必然推导（L0/L1 级），严禁越级猜测，不读真实雷位。
class_name HintSolver
extends RefCounted

## 内置 variant -> def_name 映射（供无 mod 时的默认求解）。
const VARIANT_TO_DEF := {
	ClueEngine.Variant.CLASSIC: "classic",
	ClueEngine.Variant.N4: "4n",
	ClueEngine.Variant.SAME_COLOR: "sc",
	ClueEngine.Variant.CLOCK: "clock",
	ClueEngine.Variant.FR: "fr",
	ClueEngine.Variant.LOOP_RUNS: "loopruns",
	ClueEngine.Variant.DIST_SUM: "distsum",
	ClueEngine.Variant.HV: "hv",
}

var engine := DefEngine.new()


## 一步直推（默认按 board 内置变体）。
func hint(board: Board) -> Array[ReasoningStep]:
	var def_name: String = VARIANT_TO_DEF.get(board.clue_variant, "")
	return hint_def(board, def_name)


## 一步直推（按指定线索 Def 名，支持 mod 自定义规则）。
## def_name 为空或未注册时返回空。window + aggregate 决定推理规则。
func hint_def(board: Board, def_name: String) -> Array[ReasoningStep]:
	var steps: Array[ReasoningStep] = []
	if board.grid == null:
		return steps
	if def_name == "" or not engine.clue_defs.has(def_name):
		return steps
	var def: Dictionary = engine.clue_defs[def_name]
	var window: String = def["window"]
	var aggregate: String = def["aggregate"]
	var size := board.grid.size()
	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var cell := board.grid.get_cell(pos)
			if cell.state != Cell.State.REVEALED:
				continue
			var constraint := board.get_player_constraint(pos)
			_hint_cell(board, pos, constraint, steps, window, aggregate)
	_hint_constraint(board, steps)
	if steps.is_empty():
		_hint_l2(board, def, steps)
	return steps


## 全局约束的一步直推（MX 镜像 / DT 骨牌）。只依赖已翻开的安全格，不读真实雷位、不信任旗子。
func _hint_constraint(board: Board, steps: Array[ReasoningStep]) -> void:
	match board.constraint_variant:
		ConstraintEngine.Variant.MX:
			_hint_mx(board, steps)
		ConstraintEngine.Variant.DT:
			_hint_dt(board, steps)
		_:
			pass


func _hint_cell(board: Board, pos: Vector2i, constraint: Dictionary, steps: Array[ReasoningStep], window: String, aggregate: String) -> void:
	match window:
		DefEngine.WINDOW_N8:
			if aggregate == DefEngine.AGG_WEIGHTED_SUM:
				_hint_dist_sum(board, pos, constraint, steps)
			else:
				_hint_sum_dirs(board, pos, constraint, steps, ClueEngine.ring_dirs(), "classic")
		DefEngine.WINDOW_N4:
			_hint_sum_dirs(board, pos, constraint, steps, ClueEngine.orthogonal_dirs(), "4n")
		DefEngine.WINDOW_DIAG:
			_hint_sum_dirs(board, pos, constraint, steps, ClueEngine.diagonal_dirs(), "sc")
		DefEngine.WINDOW_RING8:
			if aggregate == DefEngine.AGG_RUN_COUNT:
				_hint_loop_runs(board, pos, constraint, steps)
			else:
				_hint_clock(board, pos, constraint, steps)
		DefEngine.WINDOW_RAY_RIGHT:
			_hint_fr(board, pos, constraint, steps)
		DefEngine.WINDOW_SPLIT:
			_hint_hv(board, pos, constraint, steps)
		_:
			pass


# ============ 求和类（n8 / n4 / diag）：必安 / 必雷 ============

func _hint_sum_dirs(board: Board, pos: Vector2i, constraint: Dictionary, steps: Array[ReasoningStep], dirs: Array[Vector2i], rule: String) -> void:
	if constraint.get("type", "") != "equality":
		return
	var value: int = constraint["value"]
	var flagged := 0
	var hidden: Array[Vector2i] = []
	for p in _dir_cells(board, pos, dirs):
		var s := board.grid.get_cell(p).state
		if s == Cell.State.FLAGGED:
			flagged += 1
		elif s != Cell.State.REVEALED:
			hidden.append(p)
	if hidden.is_empty():
		return
	if flagged == value:
		for h in hidden:
			steps.append(_make_step(h, "safe", pos, rule,
				"线索 (%d,%d) 值为 %d，其邻域已标 %d 颗雷（等于 %d），故剩余 %d 格必为安全格" % [pos.y, pos.x, value, flagged, value, hidden.size()]))
	elif flagged + hidden.size() == value:
		for h in hidden:
			steps.append(_make_step(h, "mine", pos, rule,
				"线索 (%d,%d) 值为 %d，其邻域未翻开 %d 格 + 已标 %d 颗雷 恰为 %d，故剩余 %d 格必为雷" % [pos.y, pos.x, value, hidden.size(), flagged, value, hidden.size()]))


# ============ HV 纵横分计：正交 / 对角分别必安必雷 ============

func _hint_hv(board: Board, pos: Vector2i, constraint: Dictionary, steps: Array[ReasoningStep]) -> void:
	if constraint.get("type", "") != "equality_pair":
		return
	var a: int = constraint["a"]  # 正交
	var b: int = constraint["b"]  # 对角
	_hint_sum_component(board, pos, ClueEngine.orthogonal_dirs(), a, "hv正交", steps)
	_hint_sum_component(board, pos, ClueEngine.diagonal_dirs(), b, "hv对角", steps)


func _hint_sum_component(board: Board, pos: Vector2i, dirs: Array[Vector2i], value: int, rule: String, steps: Array[ReasoningStep]) -> void:
	var flagged := 0
	var hidden: Array[Vector2i] = []
	for p in _dir_cells(board, pos, dirs):
		var s := board.grid.get_cell(p).state
		if s == Cell.State.FLAGGED:
			flagged += 1
		elif s != Cell.State.REVEALED:
			hidden.append(p)
	if hidden.is_empty():
		return
	if flagged == value:
		for h in hidden:
			steps.append(_make_step(h, "safe", pos, rule,
				"线索 (%d,%d) 的%s分量为 %d，已标 %d 颗雷，故剩余 %d 格必为安全格" % [pos.y, pos.x, rule, value, flagged, hidden.size()]))
	elif flagged + hidden.size() == value:
		for h in hidden:
			steps.append(_make_step(h, "mine", pos, rule,
				"线索 (%d,%d) 的%s分量为 %d，未翻开 %d 格 + 已标 %d 颗雷 恰为 %d，故剩余 %d 格必为雷" % [pos.y, pos.x, rule, value, hidden.size(), flagged, value, hidden.size()]))


# ============ DistSum 曼哈顿和：加权必安 / 必雷 ============

func _hint_dist_sum(board: Board, pos: Vector2i, constraint: Dictionary, steps: Array[ReasoningStep]) -> void:
	if constraint.get("type", "") != "equality":
		return
	var value: int = constraint["value"]
	# 正交权重 1，对角权重 2
	var o_flag := 0
	var o_hidden: Array[Vector2i] = []
	for p in _dir_cells(board, pos, ClueEngine.orthogonal_dirs()):
		var s := board.grid.get_cell(p).state
		if s == Cell.State.FLAGGED:
			o_flag += 1
		elif s != Cell.State.REVEALED:
			o_hidden.append(p)
	var d_flag := 0
	var d_hidden: Array[Vector2i] = []
	for p in _dir_cells(board, pos, ClueEngine.diagonal_dirs()):
		var s := board.grid.get_cell(p).state
		if s == Cell.State.FLAGGED:
			d_flag += 1
		elif s != Cell.State.REVEALED:
			d_hidden.append(p)
	var remaining: int = value - o_flag - 2 * d_flag
	var max_extra: int = o_hidden.size() + 2 * d_hidden.size()
	if o_hidden.is_empty() and d_hidden.is_empty():
		return
	if remaining == 0:
		for h in o_hidden + d_hidden:
			steps.append(_make_step(h, "safe", pos, "distsum",
				"线索 (%d,%d) 曼哈顿和为 %d，已标雷的加权和已等于 %d，故剩余格必为安全格" % [pos.y, pos.x, value, value]))
	elif remaining == max_extra:
		for h in o_hidden + d_hidden:
			steps.append(_make_step(h, "mine", pos, "distsum",
				"线索 (%d,%d) 曼哈顿和为 %d，剩余格即使全为雷也恰等于目标，故剩余格必为雷" % [pos.y, pos.x, value]))


# ============ Clock 钟点：方位序锁定 ============

func _hint_clock(board: Board, pos: Vector2i, constraint: Dictionary, steps: Array[ReasoningStep]) -> void:
	if constraint.get("type", "") != "equality":
		return
	var value: Variant = constraint["value"]
	if not (value is int):
		return
	var k: int = value
	var ring := ClueEngine.ring_dirs()
	if k == 0:
		for d in ring:
			var p := pos + d
			if board.grid.in_board(p) and board.grid.get_cell(p).state != Cell.State.REVEALED:
				steps.append(_make_step(p, "safe", pos, "clock",
					"线索 (%d,%d) 钟点值为 0，表示周围 8 邻全无雷，故该格必为安全格" % [pos.y, pos.x]))
		return
	for i in ring.size():
		var p := pos + ring[i]
		if not board.grid.in_board(p):
			continue
		var dir_num := i + 1
		var s := board.grid.get_cell(p).state
		if s == Cell.State.REVEALED:
			continue
		if dir_num < k:
			steps.append(_make_step(p, "safe", pos, "clock",
				"线索 (%d,%d) 钟点值为 %d，方位 %d 之前的方位均无雷，故该格（方位 %d）必为安全格" % [pos.y, pos.x, k, dir_num, dir_num]))
		elif dir_num == k:
			steps.append(_make_step(p, "mine", pos, "clock",
				"线索 (%d,%d) 钟点值为 %d，第一颗雷在方位 %d，故该格必为雷" % [pos.y, pos.x, k, dir_num]))
			break
		else:
			break


# ============ FR 首雷：射线锁定 ============

func _hint_fr(board: Board, pos: Vector2i, constraint: Dictionary, steps: Array[ReasoningStep]) -> void:
	if constraint.get("type", "") != "equality":
		return
	var value: Variant = constraint["value"]
	var cols := board.grid.size().x
	if value is String:  # "inf"：右侧全安全
		var c := pos.x
		while c + 1 < cols:
			c += 1
			var p := Vector2i(c, pos.y)
			if board.grid.get_cell(p).state != Cell.State.REVEALED:
				steps.append(_make_step(p, "safe", pos, "fr",
					"线索 (%d,%d) 首雷值为 ∞，表示右侧全程无雷，故该格必为安全格" % [pos.y, pos.x]))
		return
	var k: int = value
	var c := pos.x
	var idx := 0
	while c + 1 < cols:
		c += 1
		idx += 1
		var p := Vector2i(c, pos.y)
		var s := board.grid.get_cell(p).state
		if idx <= k:
			if s != Cell.State.REVEALED:
				steps.append(_make_step(p, "safe", pos, "fr",
					"线索 (%d,%d) 首雷值为 %d，前 %d 格均安全，故该格必为安全格" % [pos.y, pos.x, k, k]))
		elif idx == k + 1:
			if s != Cell.State.REVEALED:
				steps.append(_make_step(p, "mine", pos, "fr",
					"线索 (%d,%d) 首雷值为 %d，第一颗雷在第 %d 格，故该格必为雷" % [pos.y, pos.x, k, idx]))
			break
		else:
			break


# ============ LoopRuns 环游程：值 0 全安全（复杂情况留待归谬层） ============

func _hint_loop_runs(board: Board, pos: Vector2i, constraint: Dictionary, steps: Array[ReasoningStep]) -> void:
	if constraint.get("type", "") != "equality":
		return
	var value: Variant = constraint["value"]
	if not (value is int):
		return
	if value == 0:
		for d in ClueEngine.ring_dirs():
			var p := pos + d
			if board.grid.in_board(p) and board.grid.get_cell(p).state != Cell.State.REVEALED:
				steps.append(_make_step(p, "safe", pos, "loopruns",
					"线索 (%d,%d) 环游程值为 0，表示环上无雷，故该格必为安全格" % [pos.y, pos.x]))


# ============ 全局约束推理 ============

## MX 镜像：已翻开的安全格 → 镜像格必安全。
func _hint_mx(board: Board, steps: Array[ReasoningStep]) -> void:
	var cols := board.grid.size().x
	var gsize := board.grid.size()
	for r in gsize.y:
		for c in gsize.x:
			var mirror_x := cols - 1 - c
			if mirror_x <= c:
				continue  # 只处理左半区 → 右半区
			var pos := Vector2i(c, r)
			var mirror := Vector2i(mirror_x, r)
			if board.grid.get_cell(pos).state != Cell.State.REVEALED:
				continue
			if board.grid.get_cell(mirror).state == Cell.State.REVEALED:
				continue
			steps.append(_make_step(mirror, "safe", pos, "mx",
				"镜像约束：左半区格 (%d,%d) 已翻开为安全，其镜像格 (%d,%d) 必为安全" % [r, c, r, mirror_x]))


## DT 骨牌：骨牌两格恰一雷，已翻开安全 → 另一格必雷。
func _hint_dt(board: Board, steps: Array[ReasoningStep]) -> void:
	for d in board.dominoes:
		if d.size() < 2:
			continue
		var a: Vector2i = d[0]
		var b: Vector2i = d[1]
		var sa := board.grid.get_cell(a).state
		var sb := board.grid.get_cell(b).state
		if sa == Cell.State.REVEALED and sb != Cell.State.REVEALED:
			steps.append(_make_step(b, "mine", a, "dt",
				"骨牌约束：骨牌两格恰一雷，(%d,%d) 已安全，故 (%d,%d) 必为雷" % [a.y, a.x, b.y, b.x]))
		elif sb == Cell.State.REVEALED and sa != Cell.State.REVEALED:
			steps.append(_make_step(a, "mine", b, "dt",
				"骨牌约束：骨牌两格恰一雷，(%d,%d) 已安全，故 (%d,%d) 必为雷" % [b.y, b.x, a.y, a.x]))


# ============ 工具 ============

func _dir_cells(board: Board, pos: Vector2i, dirs: Array[Vector2i]) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in dirs:
		var p := pos + d
		if board.grid.in_board(p):
			out.append(p)
	return out


func _make_step(pos: Vector2i, state: String, source: Vector2i, rule: String, proof: String) -> ReasoningStep:
	var step := ReasoningStep.new()
	step.pos = pos
	step.state = state
	step.method = "one_step"
	step.sources = [source]
	step.rule = rule
	step.proof = proof
	return step


# ============ L2 联合枚举（多线索交叉推理） ============

## L2：多线索共享 hidden 格时，回溯枚举所有满足约束的雷分布，找公共格。
## 覆盖 L0/L1 一步直推无法处理的「多线索交叉」推理（如 3 与 1 共享 2 格 → 另 2 格必雷）。
func _hint_l2(board: Board, def: Dictionary, steps: Array[ReasoningStep]) -> void:
	var window: String = def["window"]
	var aggregate: String = def["aggregate"]
	var size := board.grid.size()
	# 1) 收集线索（求和类 + HV 双值）
	var clues: Array = []
	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var cell := board.grid.get_cell(pos)
			if cell.state != Cell.State.REVEALED:
				continue
			var con := board.get_player_constraint(pos)
			for it in _l2_items(board, pos, con, window, aggregate):
				clues.append(it)
	if clues.size() < 2:
		return
	# 2) 分量划分（共享 hidden 格 → 同分量）
	var comps := _l2_components(clues)
	# 3) 逐分量枚举 + 公共格分析
	for comp in comps:
		var cells: Array[Vector2i] = comp["cells"]
		if cells.size() < 2:
			continue
		var cell_hits := {}
		for p in cells:
			cell_hits[p] = []
		var need: Array = []
		for ci in (comp["members"] as Array):
			var cl: Dictionary = clues[ci]
			var lidx: int = need.size()
			var ccs: Array = cl["cells"]
			var cws: Array = cl["weights"]
			for j in ccs.size():
				(cell_hits[ccs[j]] as Array).append([lidx, int(cws[j])])
			need.append(cl["need"])
		var groups := ConstraintFusion.fuse_groups(cells, size, board.dominoes, false, false)
		var f := ConstraintFusion.new()
		var res := f.enumerate_groups(groups, cell_hits, need, 0, cells.size(), 100, 20000)
		if res["budget_exceeded"]:
			continue
		var sols: Array = res["sols"]
		if sols.is_empty():
			continue
		var src: Vector2i = clues[comp["members"][0]]["pos"]
		for p in cells:
			var mine_in_all := true
			var safe_in_all := true
			for sol in sols:
				if (sol as Dictionary).has(p):
					safe_in_all = false
				else:
					mine_in_all = false
				if not mine_in_all and not safe_in_all:
					break
			if mine_in_all:
				steps.append(_make_step(p, "mine", src, "联合枚举",
					"多线索联合推理：该格在所有满足相关线索的雷分布中均为雷，故必为雷"))
			elif safe_in_all:
				steps.append(_make_step(p, "safe", src, "联合枚举",
					"多线索联合推理：该格在所有满足相关线索的雷分布中均为安全，故必为安全"))


## 线索格 → 多条 L2 子线索（HV 拆两条；只支持求和/加权/双值，模式线索跳过）。
func _l2_items(board: Board, pos: Vector2i, con: Dictionary, window: String, aggregate: String) -> Array:
	var out: Array = []
	match window:
		DefEngine.WINDOW_N8:
			if aggregate == DefEngine.AGG_WEIGHTED_SUM:
				if con.get("type", "") == "equality" and (con.get("value", 0) is int):
					out.append(_l2_sum_item(board, pos, ClueEngine.ring_dirs(), int(con["value"]), true))
			else:
				if con.get("type", "") == "equality" and (con.get("value", 0) is int):
					out.append(_l2_sum_item(board, pos, ClueEngine.ring_dirs(), int(con["value"]), false))
		DefEngine.WINDOW_N4:
			if con.get("type", "") == "equality" and (con.get("value", 0) is int):
				out.append(_l2_sum_item(board, pos, ClueEngine.orthogonal_dirs(), int(con["value"]), false))
		DefEngine.WINDOW_DIAG:
			if con.get("type", "") == "equality" and (con.get("value", 0) is int):
				out.append(_l2_sum_item(board, pos, ClueEngine.diagonal_dirs(), int(con["value"]), false))
		DefEngine.WINDOW_SPLIT:
			if con.get("type", "") == "equality_pair":
				out.append(_l2_sum_item(board, pos, ClueEngine.orthogonal_dirs(), int(con["a"]), false))
				out.append(_l2_sum_item(board, pos, ClueEngine.diagonal_dirs(), int(con["b"]), false))
	return out


## 单条求和子线索：{pos, need, cells, weights}。
func _l2_sum_item(board: Board, pos: Vector2i, dirs: Array[Vector2i], value: int, weighted: bool) -> Dictionary:
	var hidden: Array[Vector2i] = []
	var weights: Array = []
	var flagged := 0
	for d in dirs:
		var p: Vector2i = pos + d
		if not board.grid.in_board(p):
			continue
		var s := board.grid.get_cell(p).state
		var w := 1
		if weighted and d.x != 0 and d.y != 0:
			w = 2  # 对角权重 2
		if s == Cell.State.FLAGGED:
			flagged += w
		elif s != Cell.State.REVEALED:
			hidden.append(p)
			weights.append(w)
	return {"pos": pos, "need": value - flagged, "cells": hidden, "weights": weights}


## 分量划分：共享 hidden 格的两条线索同分量。
func _l2_components(clues: Array) -> Array:
	var cell_to_clue := {}
	for i in clues.size():
		for p in (clues[i]["cells"] as Array):
			if not cell_to_clue.has(p):
				cell_to_clue[p] = []
			(cell_to_clue[p] as Array).append(i)
	var comp_of := {}
	var comps: Array = []
	for i in clues.size():
		if comp_of.has(i):
			continue
		var ci: int = comps.size()
		comp_of[i] = ci
		var stack: Array = [i]
		var members: Array = []
		var cell_seen := {}
		var cells_arr: Array[Vector2i] = []
		while not stack.is_empty():
			var k: int = stack.pop_back()
			members.append(k)
			for p in (clues[k]["cells"] as Array):
				if not cell_seen.has(p):
					cell_seen[p] = true
					cells_arr.append(p)
				for j in (cell_to_clue[p] as Array):
					if not comp_of.has(j):
						comp_of[j] = ci
						stack.append(j)
		comps.append({"members": members, "cells": cells_arr})
	return comps
