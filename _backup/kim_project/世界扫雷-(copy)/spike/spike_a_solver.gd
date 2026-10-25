# spike_a_solver.gd —— Spike A：完美玩家模拟内核（L0/L1/L2，无 L3，经典 8 邻）
#
# 定位：plan1.8 §7.1 Spike A。只做模拟内核，不复现生成器。
# 红线遵守：本文件在 res://spike/ 下，不修改 core/ 任何文件；
#          求解只经 board.get_player_constraint(pos)（双视角唯一入口）；
#          判负只经 board.is_mine(pos)；不读 _static_mines 作弊。
#
# L0/L1 = SolverBasic.propagate()（已就绪的一步直推）
# L2    = 邻域枚举共同法：frontier 分量内回溯枚举 + 计数剪枝（本文件实现）
# 终止判据 = plan1.8 §1.1.2：「本轮无新增确定格」才退出（同时消除死循环与漏推）
class_name SpikeASolver
extends RefCounted

const MAX_COMPONENT_CELLS := 16    # 分量格数上限（超过直接放弃该分量）
const MAX_SOLUTIONS := 20000       # 单分量解数上限（保护）
const MAX_ENUM_NODES := 30000      # ★ 单分量回溯节点预算（超即放弃该分量，只少推不推错 = sound）
const ROUND_LIMIT_SLACK := 8       # 轮数硬上限 = N + 本值（只作兜底断言，正常不触发）
const L3_MAX_DEPTH := 2            # L3 有界归谬深度
const MAX_INTERIOR_INCLUDE := 8    # 容量约束涉及的 interior 格纳入枚举上限（超则退回区间放宽，只少推不推错）
const L3_BUDGET := 2000            # L3 假设传播次数预算

var _node_count := 0               # 当前分量回溯节点计数
var _budget_exceeded := false      # 当前分量是否触发节点预算
var _l3_nodes := 0                 # L3 假设节点计数（含深度 2 递归）

var stats := {
	"simulate_calls": 0,
	"rounds": 0,
	"l0_only_rounds": 0,
	"l2_rounds": 0,
	"l2_nodes": 0,
	"l2_components": 0,
	"l2_skipped_big": 0,
	"l2_budget_hits": 0,
	"deduced_safe": 0,
	"deduced_mine": 0,
	"max_rounds_seen": 0,
	"mine_only_rounds": 0,        # 本轮有新增但全来自必雷格（T-A/T-B 场景真实发生次数）
	"verify_calls": 0,
	"verify_violations": 0,
	"l3_rounds": 0,               # 进入 L3 的轮次
	"l3_nodes": 0,                # L3 假设节点总数
	"l3_budget_hits": 0,          # L3 触发预算熔断的次数
}


# ───────────────────────── 变体感知（Spike C 扩展） ─────────────────────────

## 线索变体。本 Spike 只支持「单值计数」线索（CLASSIC / N4 / SAME_COLOR）：
##   CLASSIC     窗口 = 8 邻，值 = 窗口雷数
##   N4          窗口 = 4 正交，值 = 窗口雷数
##   SAME_COLOR  窗口 = 4 对角，值 = 窗口雷数
## 非计数型（CLOCK/LOOP_RUNS/FR/HV/DIST_SUM）需通用窗口枚举传播器（plan1.8 §3.2），不在本 Spike 范围。
var clue_variant: int = ClueEngine.Variant.CLASSIC
var l3_enabled: bool = true          # L3 有界归谬开关（Spike D 对比 L0~L2 vs L0~L3）
var l3_depth: int = 2                # L3 归谬深度（可调：量化时可用 1 加速）

var _dirs_cache: Array[Vector2i] = []
var _dirs_cache_variant: int = -99
var _nb_cache: Dictionary = {}       # pos -> Array[Vector2i]（按 board size + 变体缓存，避免重复分配）
var _nb_cache_size: Vector2i = Vector2i(-1, -1)
var _nb_cache_variant: int = -99


func _is_count_based() -> bool:
	return clue_variant == ClueEngine.Variant.CLASSIC \
		or clue_variant == ClueEngine.Variant.N4 \
		or clue_variant == ClueEngine.Variant.SAME_COLOR \
		or clue_variant == ClueEngine.Variant.DIST_SUM \
		or clue_variant == ClueEngine.Variant.HV


## 线索格 pos 的邻格 nb 的权重（DIST_SUM：正交 1、对角 2；其余计数型恒 1）。
func _clue_weight(pos: Vector2i, nb: Vector2i) -> int:
	if clue_variant == ClueEngine.Variant.DIST_SUM:
		var d := nb - pos
		if d.x == 0 or d.y == 0:
			return 1  # 正交
		return 2  # 对角
	return 1


## pos 在 dirs 方向上的界内邻居。
func _nb_in_dirs(pos: Vector2i, size: Vector2i, dirs: Array[Vector2i]) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in dirs:
		var p: Vector2i = pos + d
		if p.x >= 0 and p.x < size.x and p.y >= 0 and p.y < size.y:
			out.append(p)
	return out


## 线索格约束 → 多条 {value, nbs} 子线索。HV 双值拆成正交 + 对角两条。
func _clue_sub_items(con: Dictionary, pos: Vector2i, size: Vector2i) -> Array:
	var out: Array = []
	match con.get("type", ""):
		"equality":
			if con.get("value", 0) is int:
				out.append({"value": con["value"], "nbs": _window(pos, size)})
		"equality_pair":
			out.append({"value": con["a"], "nbs": _nb_in_dirs(pos, size, ClueEngine.orthogonal_dirs())})
			out.append({"value": con["b"], "nbs": _nb_in_dirs(pos, size, ClueEngine.diagonal_dirs())})
	return out


func _dirs() -> Array[Vector2i]:
	if _dirs_cache_variant != clue_variant:
		match clue_variant:
			ClueEngine.Variant.N4:
				_dirs_cache = ClueEngine.orthogonal_dirs()
			ClueEngine.Variant.SAME_COLOR:
				_dirs_cache = ClueEngine.diagonal_dirs()
			_:
				_dirs_cache = ClueEngine.ring_dirs()
		_dirs_cache_variant = clue_variant
	return _dirs_cache


## 变体对应的「线索窗口」：该格线索会统计哪些邻居的雷。带缓存。
func _window(pos: Vector2i, size: Vector2i) -> Array[Vector2i]:
	if _nb_cache_size != size or _nb_cache_variant != clue_variant:
		_rebuild_nb_cache(size)
	return _nb_cache.get(pos, [])


func _rebuild_nb_cache(size: Vector2i) -> void:
	_nb_cache.clear()
	_nb_cache_size = size
	_nb_cache_variant = clue_variant
	var dirs := _dirs()
	for y in size.y:
		for x in size.x:
			var pos := Vector2i(x, y)
			var out: Array[Vector2i] = []
			for d in dirs:
				var p := pos + d
				if p.x >= 0 and p.x < size.x and p.y >= 0 and p.y < size.y:
					out.append(p)
			_nb_cache[pos] = out


# ───────────────────────── 对外主入口 ─────────────────────────

## 完美玩家模拟。board 必须是「已布雷、未翻开任何格」的全新实例。
## s0 为初始翻开格（必须全部非雷）。
## verify 可选回调 Callable(board, deduced_dict)，用于 soundness 外部校验（Spike A 用 Oracle 比对）。
## 返回 { success, reason, rounds, revealed, target, solved_by, mine_only_round_hit }
func simulate(board: Board, s0: Array[Vector2i], verify := Callable()) -> Dictionary:
	stats.simulate_calls += 1
	clue_variant = board.clue_variant  # 关键：从 board 同步线索变体（4N/SC），否则窗口方向错推
	var size := board.grid.size()
	var N: int = size.x * size.y
	var M: int = board.total_mines
	var target: int = N - M
	var determined := {}              # pos -> 0(safe) / 1(mine)
	var opened: Array[Vector2i] = []
	var rounds := 0
	var used_l2 := false
	var hit_mine_only := false        # 本局是否出现过「只推出必雷格」的轮次
	var round_limit: int = N + ROUND_LIMIT_SLACK

	# ── 翻开 S₀（用变体感知 reveal，不用 board.reveal 的 classic flood） ──
	for p in s0:
		if board.is_mine(p):
			return _result(false, "s0_is_mine", rounds, 0, target, used_l2, false)
		_reveal_manual(board, p)

	# ── 主循环（plan1.8 §1.1.2 定稿） ──
	while true:
		rounds += 1
		stats.rounds += 1
		if rounds > stats.max_rounds_seen:
			stats.max_rounds_seen = rounds

		var d := _deduce(board)
		var newly := 0
		var safe_added := 0

		# soundness 外部校验（Spike A：与 Oracle 比对，L2 结论必须是 Oracle 结论的子集）
		if verify.is_valid():
			stats.verify_calls += 1
			if not verify.call(board, d):
				stats.verify_violations += 1

		# ② apply 必雷格（plan1.7 缺失的一环）
		for m in (d["mine"] as Array):
			if determined.has(m):
				continue
			determined[m] = 1
			var c := board.grid.get_cell(m)
			if c.state == Cell.State.HIDDEN:
				board.toggle_flag(m)      # HIDDEN -> FLAGGED
			newly += 1
			stats.deduced_mine += 1

		# ③ apply 必安格（变体感知 reveal）
		for s in (d["safe"] as Array):
			if determined.has(s):
				continue
			determined[s] = 0
			opened.append(s)
			_reveal_manual(board, s)
			newly += 1
			safe_added += 1
			stats.deduced_safe += 1

		# T-A / T-B 观测：本轮有推进但全部来自必雷格
		if newly > 0 and safe_added == 0:
			stats.mine_only_rounds += 1
			hit_mine_only = true

		# ④ 终止判据：无新增确定格 或 已翻开全部安全格
		if newly == 0:
			break
		if _count_revealed(board) == target:
			break

	if rounds > round_limit:
		return _result(false, "round_overflow", rounds, _count_revealed(board), target, used_l2, hit_mine_only)

	var revealed := _count_revealed(board)
	var won := revealed == target
	return _result(won, "ok" if won else "chain_break", rounds, revealed, target, used_l2, hit_mine_only)


## 变体感知 reveal：值 0 ⇒ 仅沿「线索窗口」扩散（不沿引擎的 8 邻 classic flood）。
## 引擎 board._flood_reveal 是 classic-only（8 邻硬编码 + 雷格 value=0 被误判为 0 线索），
## 非经典变体下会翻开对角/射线外的雷 ⇒ 本 Spike 自实现正确扩散。
func _reveal_manual(board: Board, start: Vector2i) -> void:
	var size := board.grid.size()
	var stack: Array[Vector2i] = [start]
	var visited := {}
	while not stack.is_empty():
		var p: Vector2i = stack.pop_back()
		if visited.has(p):
			continue
		visited[p] = true
		var cell := board.grid.get_cell(p)
		if cell.state != Cell.State.HIDDEN:
			continue
		if cell.is_mine:
			continue        # sound 求解器不会翻到雷；防御性跳过
		cell.state = Cell.State.REVEALED
		var con: Dictionary = cell.get_player_constraint()
		if con.get("type", "") == "equality" and con.get("value", 0) is int and con["value"] == 0:
			for nb in _window(p, size):
				if board.grid.get_cell(nb).state == Cell.State.HIDDEN:
					stack.append(nb)


func _result(ok: bool, reason: String, rounds: int, revealed: int, target: int, l2: bool, mine_only: bool) -> Dictionary:
	return {
		"success": ok,
		"reason": reason,
		"rounds": rounds,
		"revealed": revealed,
		"target": target,
		"solved_by_l2": l2,
		"mine_only_round_hit": mine_only,
	}


# ───────────────────────── 推理：L0/L1 → L2 ─────────────────────────

## 分层升级：L0/L1 有结论就返回，全部无结论才进 L2。
func _deduce(board: Board) -> Dictionary:
	var safe: Array[Vector2i] = []
	var mine: Array[Vector2i] = []

	# 非计数型线索本 Spike 不支持 ⇒ 宁可断链也不推错（sound 优先）
	if not (_is_count_based() or _is_mode_based()):
		return {"safe": safe, "mine": mine}

	# L0 / L1（一步直推，变体感知；SolverBasic 是 8 邻硬编码，非经典不能复用）
	# 仅计数型线索走 _deduce_l01（加权求和直推）；模式线索跳过（不是求和约束）
	var r: Dictionary = {}
	if _is_count_based():
		r = _deduce_l01(board)
		for s in (r.get("safe", []) as Array):
			if not safe.has(s):
				safe.append(s)
		for m in (r.get("mine", []) as Array):
			if not mine.has(m):
				mine.append(m)
	# 模式线索（CLOCK/FR/LOOP_RUNS）：环序/射线锁定，L0/L1 可一步直推，但不能进 L2 加权枚举
	if _is_mode_based():
		var rm: Dictionary = _deduce_mode(board)
		for s in (rm.get("safe", []) as Array):
			if not safe.has(s):
				safe.append(s)
		for m in (rm.get("mine", []) as Array):
			if not mine.has(m):
				mine.append(m)
	# 全局约束 L0/L1 直推（MX 镜像 / DT 骨牌：已确定格 → 未确定格，sound 一步直推）
	if _has_global_constraint(board):
		_deduce_global_l01(board, safe, mine)
	if not safe.is_empty() or not mine.is_empty():
		stats.l0_only_rounds += 1
		return {"safe": safe, "mine": mine}

	# L2（邻域枚举共同法，仅计数型线索可走）
	if not _is_count_based():
		return {"safe": safe, "mine": mine}
	stats.l2_rounds += 1
	var r2 := _deduce_l2(board)
	for s in (r2.get("safe", []) as Array):
		if not safe.has(s):
			safe.append(s)
	for m in (r2.get("mine", []) as Array):
		if not mine.has(m):
			mine.append(m)
	if not safe.is_empty() or not mine.is_empty():
		return {"safe": safe, "mine": mine}

	# L3（深度 2 有界归谬，plan1.8 §1.2.2）
	if l3_enabled:
		stats.l3_rounds += 1
		_l3_nodes = 0
		var r3 := _deduce_l3(board)
		stats.l3_nodes += _l3_nodes
		for s in (r3.get("safe", []) as Array):
			if not safe.has(s):
				safe.append(s)
		for m in (r3.get("mine", []) as Array):
			if not mine.has(m):
				mine.append(m)
	return {"safe": safe, "mine": mine}


## 模式线索（CLOCK/FR/LOOP_RUNS）：环序/射线结构锁定 ⇒ 可一步直推。
## 但 L2 加权枚举不适用（不是求和/加权求和约束），故跳过 L2。
func _is_mode_based() -> bool:
	return clue_variant == ClueEngine.Variant.CLOCK \
		or clue_variant == ClueEngine.Variant.FR \
		or clue_variant == ClueEngine.Variant.LOOP_RUNS


## 模式线索 L0/L1：CLOCK 方位序锁定、FR 射线锁定、LOOP_RUNS 环上零雷锁定。
## 仅基于「线索值 + 已确定格」推一步，sound（不读雷位、不越级猜测）。
func _deduce_mode(board: Board) -> Dictionary:
	var safe: Array[Vector2i] = []
	var mine: Array[Vector2i] = []
	var size := board.grid.size()
	for y in size.y:
		for x in size.x:
			var pos := Vector2i(x, y)
			if board.grid.get_cell(pos).state != Cell.State.REVEALED:
				continue
			var con: Dictionary = board.get_player_constraint(pos)
			# "?" 遮蔽格 type="interval"，con.get("value",0) 默认返回 0，会被错误当 CLOCK=0 处理 ⇒ 必须跳过
			if con.get("type", "") != "equality":
				continue
			match clue_variant:
				ClueEngine.Variant.CLOCK:
					_deduce_clock(board, pos, con, safe, mine)
				ClueEngine.Variant.FR:
					_deduce_fr(board, pos, con, safe, mine)
				ClueEngine.Variant.LOOP_RUNS:
					_deduce_loop_runs(board, pos, con, safe, mine)
	return {"safe": safe, "mine": mine}


## CLOCK：8 邻顺时针首雷方位（1~8）；value=0 ⇒ 全 8 邻安全；value=k ⇒ 前 k-1 格安全 + 第 k 格雷。
func _deduce_clock(board: Board, pos: Vector2i, con: Dictionary, safe: Array, mine: Array) -> void:
	var value: Variant = con.get("value", 0)
	if not (value is int):
		return
	var k: int = value
	var size := board.grid.size()
	var ring := ClueEngine.ring_dirs()
	# 先检查冲突（已旗格与线索值矛盾）：此情形 sound 应断链而非推错，跳过该格
	var first_mine_dir := -1  # 已知的第一个雷在环序中的索引（0-based）
	for i in ring.size():
		var p := pos + ring[i]
		if not board.grid.in_board(p):
			continue
		if board.grid.get_cell(p).state == Cell.State.FLAGGED:
			if first_mine_dir == -1:
				first_mine_dir = i
			else:
				return  # 多个已旗 ⇒ 矛盾或需要 L2+ 处理，跳过
		elif board.grid.get_cell(p).state == Cell.State.REVEALED:
			# 已翻开雷不可能（模拟器不会翻到雷），跳过
			pass
	if k == 0:
		# 全 8 邻安全（越界格忽略）
		for d in ring:
			var p := pos + d
			if board.grid.in_board(p) and board.grid.get_cell(p).state != Cell.State.FLAGGED:
				if not safe.has(p):
					safe.append(p)
		return
	# value=k (1..8)：环序 0..k-2 安全，第 k-1 格是雷
	# 若 first_mine_dir 已确定且 ≠ k-1 ⇒ 矛盾，跳过
	if first_mine_dir >= 0 and first_mine_dir != k - 1:
		return
	for i in k - 1:
		var d: Vector2i = ring[i]
		var p := pos + d
		if not board.grid.in_board(p):
			continue
		if board.grid.get_cell(p).state != Cell.State.FLAGGED:
			if not safe.has(p):
				safe.append(p)
	# 第 k-1 格是雷
	var mine_p := pos + ring[k - 1]
	if board.grid.in_board(mine_p) and board.grid.get_cell(mine_p).state != Cell.State.FLAGGED:
		if not mine.has(mine_p):
			mine.append(mine_p)


## FR：向右射线首雷位置；value="inf" 或 k=0 ⇒ 全右侧安全；value=k ⇒ 前 k 格安全 + 第 k+1 格雷。
func _deduce_fr(board: Board, pos: Vector2i, con: Dictionary, safe: Array, mine: Array) -> void:
	var value: Variant = con.get("value", 0)
	var k: int = 0
	var is_inf := false
	if value is String and value == "inf":
		is_inf = true
	elif value is int:
		k = value
	else:
		return
	var cols := board.grid.size().x
	if is_inf or k == 0:
		# 全右侧安全
		var c := pos.x + 1
		while c < cols:
			var p := Vector2i(c, pos.y)
			if board.grid.get_cell(p).state != Cell.State.FLAGGED:
				if not safe.has(p):
					safe.append(p)
			c += 1
		return
	# value=k (1..cols-pos.x-1)：前 k 格安全 + 第 k+1 格雷
	var mine_p := Vector2i(pos.x + k + 1, pos.y)
	# 边界检查：mine_p 必须存在且与已旗位置一致
	if board.grid.in_board(mine_p):
		var check_first_mine := true
		# 检查前 k 格确为安全（无旗）
		var c := pos.x + 1
		for i in k:
			if c >= cols:
				check_first_mine = false
				break
			var p := Vector2i(c, pos.y)
			if board.grid.get_cell(p).state == Cell.State.FLAGGED:
				check_first_mine = false
				break
			c += 1
		# 检查 mine_p 是否已被旗
		if check_first_mine and board.grid.get_cell(mine_p).state != Cell.State.FLAGGED:
			if not mine.has(mine_p):
				mine.append(mine_p)
		# 前 k 格标安全
		c = pos.x + 1
		for i in k:
			if c >= cols:
				break
			var p := Vector2i(c, pos.y)
			if board.grid.get_cell(p).state != Cell.State.FLAGGED:
				if not safe.has(p):
					safe.append(p)
			c += 1


## LOOP_RUNS：8 邻环序连续雷段数；仅 value=0 ⇒ 全环安全（环上有 0 段雷）。
## value>=1 需要更多全局推理（L2+），此处不推（宁可断链）。
func _deduce_loop_runs(board: Board, pos: Vector2i, con: Dictionary, safe: Array, mine: Array) -> void:
	var value: Variant = con.get("value", 0)
	if not (value is int):
		return
	if value == 0:
		for d in ClueEngine.ring_dirs():
			var p := pos + d
			if board.grid.in_board(p) and board.grid.get_cell(p).state != Cell.State.FLAGGED:
				if not safe.has(p):
					safe.append(p)


## L0/L1 一步直推（变体感知）：对每个已翻开的等值整数线索格，按线索窗口统计旗数/未知数。
func _deduce_l01(board: Board) -> Dictionary:
	var safe: Array[Vector2i] = []
	var mine: Array[Vector2i] = []
	var size := board.grid.size()
	for y in size.y:
		for x in size.x:
			var pos := Vector2i(x, y)
			var con: Dictionary = board.get_player_constraint(pos)
			for sc in _clue_sub_items(con, pos, size):
				var value: int = sc["value"]
				var nbs: Array = sc["nbs"]
				var flagged := 0
				var hidden: Array[Vector2i] = []
				var hidden_weight_sum := 0
				for nb in nbs:
					var nc := board.grid.get_cell(nb)
					var w := _clue_weight(pos, nb)
					if nc.state == Cell.State.FLAGGED:
						flagged += w
					elif nc.state != Cell.State.REVEALED:
						hidden.append(nb)
						hidden_weight_sum += w
				if hidden.is_empty():
					continue
				if flagged == value:
					for h in hidden:
						if not safe.has(h):
							safe.append(h)
				elif flagged + hidden_weight_sum == value:
					for h in hidden:
						if not mine.has(h):
							mine.append(h)
	return {"safe": safe, "mine": mine}


## 全局约束 L0/L1 一步直推：MX 镜像（相等）/ DT 骨牌（恰一雷）的「已确定格 → 未确定格」。
## 这是融合枚举（L2）之外必须补的一块：L2 只融合同在 frontier 的配对，这里处理「一格已定」的配对。
func _deduce_global_l01(board: Board, safe: Array[Vector2i], mine: Array[Vector2i]) -> void:
	for c in board.get_player_global_constraints():
		match c.get("type", ""):
			"mx":
				_deduce_mx_l01(board, safe, mine)
			"dt":
				_deduce_dt_l01(board, safe, mine, c.get("dominoes", []))


## MX 镜像：镜像对状态相等。已翻开(安全)→镜像必安全；已插旗(雷)→镜像必雷。
func _deduce_mx_l01(board: Board, safe: Array[Vector2i], mine: Array[Vector2i]) -> void:
	var size := board.grid.size()
	var cols: int = size.x
	for y in size.y:
		for x in cols:
			var mirror_x := cols - 1 - x
			if mirror_x <= x:
				continue
			var p := Vector2i(x, y)
			var m := Vector2i(mirror_x, y)
			var sp := board.grid.get_cell(p).state
			var sm := board.grid.get_cell(m).state
			if sp == Cell.State.REVEALED and sm == Cell.State.HIDDEN and not safe.has(m):
				safe.append(m)
			elif sp == Cell.State.FLAGGED and sm == Cell.State.HIDDEN and not mine.has(m):
				mine.append(m)
			if sm == Cell.State.REVEALED and sp == Cell.State.HIDDEN and not safe.has(p):
				safe.append(p)
			elif sm == Cell.State.FLAGGED and sp == Cell.State.HIDDEN and not mine.has(p):
				mine.append(p)


## DT 骨牌：两格恰一雷。一格安全(REVEALED)→另一格必雷；一格雷(FLAGGED)→另一格必安全。
func _deduce_dt_l01(board: Board, safe: Array[Vector2i], mine: Array[Vector2i], dominoes: Array) -> void:
	for d in dominoes:
		if d.size() < 2:
			continue
		var a: Vector2i = d[0]
		var b: Vector2i = d[1]
		var sa := board.grid.get_cell(a).state
		var sb := board.grid.get_cell(b).state
		if sa == Cell.State.REVEALED and sb == Cell.State.HIDDEN and not mine.has(b):
			mine.append(b)
		elif sa == Cell.State.FLAGGED and sb == Cell.State.HIDDEN and not safe.has(b):
			safe.append(b)
		if sb == Cell.State.REVEALED and sa == Cell.State.HIDDEN and not mine.has(a):
			mine.append(a)
		elif sb == Cell.State.FLAGGED and sa == Cell.State.HIDDEN and not safe.has(a):
			safe.append(a)


## L2：frontier 分量内回溯枚举。
## soundness：分量独立枚举 + 全局雷数区间松弛 ⇒ 只可能「少推」不可能「推错」。
func _deduce_l2(board: Board) -> Dictionary:
	var safe: Array[Vector2i] = []
	var mine: Array[Vector2i] = []
	var size := board.grid.size()

	# 1) 收集已翻开的「等值整数线索格」与已插旗数
	var clue_cells: Array[Vector2i] = []
	var flagged_count := 0
	for y in size.y:
		for x in size.x:
			var p := Vector2i(x, y)
			var c := board.grid.get_cell(p)
			if c.state == Cell.State.FLAGGED:
				flagged_count += 1
			elif c.state == Cell.State.REVEALED:
				var con: Dictionary = c.get_player_constraint()
				if not _clue_sub_items(con, p, size).is_empty():
					clue_cells.append(p)
	if clue_cells.is_empty():
		return {"safe": safe, "mine": mine}

	# 2) 每条线索格展开成多条子线索（HV 双值拆成正交 + 对角）
	var clues: Array = []
	for p in clue_cells:
		var con: Dictionary = board.grid.get_cell(p).get_player_constraint()
		for sc in _clue_sub_items(con, p, size):
			var value: int = sc["value"]
			var nbs: Array = sc["nbs"]
			var hid: Array[Vector2i] = []
			var hid_w: Array = []
			var flg := 0
			for nb in nbs:
				var nc := board.grid.get_cell(nb)
				var w := _clue_weight(p, nb)
				if nc.state == Cell.State.FLAGGED:
					flg += w
				elif nc.state != Cell.State.REVEALED:
					hid.append(nb)
					hid_w.append(w)
			if hid.is_empty():
				continue
			clues.append({"pos": p, "need": value - flg, "cells": hid, "weights": hid_w})
	if clues.is_empty():
		return {"safe": safe, "mine": mine}

	# 3) 分量划分：两条线索共享一个 hidden 格 ⇒ 同分量
	var cell_to_clues := {}
	for i in clues.size():
		for cpos in (clues[i]["cells"] as Array):
			if not cell_to_clues.has(cpos):
				cell_to_clues[cpos] = []
			(cell_to_clues[cpos] as Array).append(i)

	var comp_of := {}
	var comps: Array = []
	for i in clues.size():
		if comp_of.has(i):
			continue
		var comp_idx: int = comps.size()
		comp_of[i] = comp_idx
		var stack: Array = [i]
		var members: Array = []
		while not stack.is_empty():
			var ci: int = stack.pop_back()
			members.append(ci)
			for cpos in (clues[ci]["cells"] as Array):
				for cj in (cell_to_clues[cpos] as Array):
					if not comp_of.has(cj):
						comp_of[cj] = comp_idx
						stack.append(cj)
		comps.append(members)

	# 4) 全局量：frontier 全集、interior（既非 frontier 也非已翻开/已插旗的格）
	var all_frontier := {}
	for cl in clues:
		for cpos in (cl["cells"] as Array):
			all_frontier[cpos] = true
	var known_mines := {}   # 已插旗（确认雷），容量约束的已知贡献
	var interior_cells: Array[Vector2i] = []  # 未知但不在 frontier（枚举范围外）
	for y in size.y:
		for x in size.x:
			var p := Vector2i(x, y)
			var c := board.grid.get_cell(p)
			if c.state == Cell.State.FLAGGED:
				known_mines[p] = true
			elif c.state != Cell.State.REVEALED:
				if not all_frontier.has(p):
					interior_cells.append(p)
	var interior: int = interior_cells.size()
	var remaining_total: int = board.total_mines - flagged_count

	# 5) 容量约束行 + 跨分量合并（4C/EP/QD/PF/RL 天然跨分量，必须联合枚举）
	var has_constraint: bool = _has_global_constraint(board)
	var frontier_arr: Array[Vector2i] = []
	for p in all_frontier:
		frontier_arr.append(p)
	# 容量约束涉及的「枚举范围外未知格」：数量可控时纳入枚举，
	# 否则约束被 interior 的不确定性稀释成几乎无约束力的宽区间。
	var outside_cells: Array[Vector2i] = []
	if has_constraint:
		outside_cells = ConstraintFusion.capacity_outside(
			board.get_player_global_constraints(), size, frontier_arr, known_mines, interior_cells)
	var include_interior: bool = (not outside_cells.is_empty()) and outside_cells.size() <= MAX_INTERIOR_INCLUDE
	var cap_rows: Array = []
	if has_constraint:
		cap_rows = ConstraintFusion.capacity_rows(
			board.get_player_global_constraints(), size, frontier_arr, known_mines, interior_cells, include_interior)
	var super_comps: Array = _merge_components(comps, clues, cap_rows)

	for sc in super_comps:
		stats.l2_components += 1
		var members: Array = sc["members"]
		var cap_rows_mine: Array = sc["cap_rows"]
		var cells: Array[Vector2i] = []
		var seen := {}
		for ci in members:
			for cpos in (clues[ci]["cells"] as Array):
				if not seen.has(cpos):
					seen[cpos] = true
					cells.append(cpos)
		# 纳入枚举的 interior 格（由容量约束驱动，不在 frontier 内）
		var n_extra := 0
		if include_interior:
			for p in (sc["extra"] as Array):
				if not seen.has(p):
					seen[p] = true
					cells.append(p)
					n_extra += 1
		if cells.size() > MAX_COMPONENT_CELLS:
			stats.l2_skipped_big += 1
			continue

		# 分量内线索 -> 局部下标（cell_hits 用 pos 作 key，存 [线索 idx, 权重] 对）
		var local_clues: Array = []
		var cell_hits: Dictionary = {}
		for p in cells:
			cell_hits[p] = []
		for ci in members:
			var need: int = clues[ci]["need"]
			var cws: Array = clues[ci]["weights"]
			var ccs: Array = clues[ci]["cells"]
			var lidx: int = local_clues.size()
			for j in ccs.size():
				(cell_hits[ccs[j]] as Array).append([lidx, int(cws[j])])
			local_clues.append({"need": need})

		# 全局雷数区间在本分量上的松弛投影（只放宽不收紧 ⇒ sound）
		# 纳入枚举的 interior 格已计入 cells，须从「未枚举 interior」中扣除
		var n_frontier_here: int = cells.size() - n_extra
		var other_frontier: int = all_frontier.size() - n_frontier_here
		var interior_eff: int = interior - n_extra
		var lo: int = maxi(0, remaining_total - interior_eff - other_frontier)
		var hi: int = mini(cells.size(), remaining_total)

		# 枚举：有全局约束走融合枚举（MX/DT 变量组 + 加权雷数），无约束走旧布尔枚举（回归不变）
		var sols: Array = []
		if has_constraint:
			# 由当前关卡真正启用的约束推导融合开关（DT 关卡绝不套 MX 镜像，反之亦然）
			var use_mx := false
			var use_dt := false
			for gc in board.get_player_global_constraints():
				match gc.get("type", ""):
					"mx":
						use_mx = true
					"dt":
						use_dt = true
			var groups := ConstraintFusion.fuse_groups(cells, size, board.dominoes, use_mx, use_dt)
			var need_arr: Array = []
			for lc in local_clues:
				need_arr.append(lc["need"])
			var f := ConstraintFusion.new()
			var r := f.enumerate_groups(groups, cell_hits, need_arr, lo, hi, MAX_SOLUTIONS, MAX_ENUM_NODES, cap_rows_mine)
			if r["budget_exceeded"]:
				stats.l2_budget_hits += 1
				continue
			sols = r["sols"]
		else:
			# 无全局约束：普通格组（等价旧布尔枚举），复用融合枚举以支持加权线索（DIST_SUM）
			var groups := ConstraintFusion.fuse_groups(cells, size, board.dominoes, false, false)
			var need_arr: Array = []
			for lc in local_clues:
				need_arr.append(lc["need"])
			var f := ConstraintFusion.new()
			var rr := f.enumerate_groups(groups, cell_hits, need_arr, lo, hi, MAX_SOLUTIONS, MAX_ENUM_NODES)
			if rr["budget_exceeded"]:
				stats.l2_budget_hits += 1
				continue
			sols = rr["sols"]

		if sols.is_empty():
			continue

		for j in cells.size():
			var pos: Vector2i = cells[j]
			var mine_in_all := true
			var safe_in_all := true
			for s in sols:
				if s.get(pos, false):
					safe_in_all = false
				else:
					mine_in_all = false
				if not mine_in_all and not safe_in_all:
					break
			if mine_in_all:
				if not mine.has(pos):
					mine.append(pos)
			elif safe_in_all:
				if not safe.has(pos):
					safe.append(pos)

	return {"safe": safe, "mine": mine}


## 关卡是否有全局约束（内置 G1~G7 或 Mod 自定义约束）。有则 L2 走融合枚举（消费 MX/DT）。
func _has_global_constraint(board: Board) -> bool:
	return board.constraint_variant >= 0 or board.constraint_variant2 >= 0 or board.constraint_def_name != ""


# ───────────────────────── 回溯枚举 ─────────────────────────

func _enumerate(clues: Array, cell_hits: Array, lo: int, hi: int) -> Array:
	var n: int = cell_hits.size()
	var assign: Array[bool] = []
	assign.resize(n)
	var counts: Array[int] = []
	counts.resize(clues.size())
	var rem: Array[int] = []
	rem.resize(clues.size())
	for i in clues.size():
		counts[i] = 0
		rem[i] = 0
	for j in n:
		for ci in (cell_hits[j] as Array):
			rem[ci] += 1
	_node_count = 0
	_budget_exceeded = false
	var sols: Array = []
	_bt(clues, cell_hits, 0, assign, counts, rem, lo, hi, 0, sols)
	if _budget_exceeded:
		stats.l2_budget_hits += 1
		return []
	return sols


func _bt(
	clues: Array, cell_hits: Array, idx: int, assign: Array,
	counts: Array, rem: Array, lo: int, hi: int, mine_count: int, sols: Array
) -> void:
	if sols.size() >= MAX_SOLUTIONS:
		return
	_node_count += 1
	if _node_count > MAX_ENUM_NODES:
		_budget_exceeded = true
		return
	var n: int = cell_hits.size()
	stats.l2_nodes += 1

	# 剪枝：雷数上下界
	if mine_count > hi:
		return
	if mine_count + (n - idx) < lo:
		return

	if idx == n:
		if mine_count < lo:
			return
		for i in clues.size():
			if counts[i] != (clues[i] as Dictionary)["need"]:
				return
		sols.append(assign.duplicate())
		return

	# 分支 1：该格非雷
	var ok := true
	for ci in (cell_hits[idx] as Array):
		rem[ci] -= 1
		if counts[ci] + rem[ci] < (clues[ci] as Dictionary)["need"]:
			ok = false
	if ok:
		assign[idx] = false
		_bt(clues, cell_hits, idx + 1, assign, counts, rem, lo, hi, mine_count, sols)
	for ci in (cell_hits[idx] as Array):
		rem[ci] += 1

	# 分支 2：该格是雷
	ok = true
	for ci in (cell_hits[idx] as Array):
		counts[ci] += 1
		rem[ci] -= 1
		var need: int = (clues[ci] as Dictionary)["need"]
		if counts[ci] > need or counts[ci] + rem[ci] < need:
			ok = false
	if ok and mine_count + 1 <= hi:
		assign[idx] = true
		_bt(clues, cell_hits, idx + 1, assign, counts, rem, lo, hi, mine_count + 1, sols)
	for ci in (cell_hits[idx] as Array):
		counts[ci] -= 1
		rem[ci] += 1


# ───────────────────────── L3 有界归谬 ─────────────────────────

## L3（深度 2 有界归谬）：对每个 frontier 格做「假设-传播-矛盾」。
## 工作在独立约束状态（need/mine/hidden 字典），【不】读真实雷位 ⇒ sound。
## 假设 c 是雷 → 传播 → 矛盾 ⇒ c 必安全；假设 c 是安全 → 传播 → 矛盾 ⇒ c 必雷。
## 用容量约束合并分量：容量行涉及的格所在分量合并成超级分量（跨分量融合）。
## comps: Array[Array[线索 idx]]；clues: 线索表；cap_rows: 容量行
## 返回 Array[Dictionary]：{ members: Array[线索 idx], cap_rows: Array }
func _merge_components(comps: Array, clues: Array, cap_rows: Array) -> Array:
	# 格 -> 分量 idx（comps[ci] 是线索 idx 数组，展开成格）
	var cell_comp := {}
	for ci in comps.size():
		for mci in (comps[ci] as Array):
			for cpos in (clues[mci]["cells"] as Array):
				cell_comp[cpos] = ci
	# union-find：每个容量行把其涉及的分量连起来
	var parent: Array = []
	for i in comps.size():
		parent.append(i)
	for r in cap_rows:
		var first := -1
		for p in (r["cells"] as Array):
			if not cell_comp.has(p):
				continue
			var root: int = _uf_find(parent, int(cell_comp[p]))
			if first < 0:
				first = root
			elif root != first:
				parent[root] = first
	# 按根收集超级分量
	var by_root := {}
	for i in comps.size():
		var root: int = _uf_find(parent, i)
		if not by_root.has(root):
			by_root[root] = {"members": [], "cap_rows": [], "extra": []}
		(by_root[root]["members"] as Array).append_array(comps[i])
	# 容量行归属到其涉及的第一个分量所在的超级分量；
	# 行里不属于任何分量的格（被纳入枚举的 interior）一并归入该超级分量
	for r in cap_rows:
		var target := -1
		for p in (r["cells"] as Array):
			if cell_comp.has(p):
				target = _uf_find(parent, int(cell_comp[p]))
				break
		if target < 0:
			continue
		(by_root[target]["cap_rows"] as Array).append(r)
		for p in (r["cells"] as Array):
			if not cell_comp.has(p) and not (by_root[target]["extra"] as Array).has(p):
				(by_root[target]["extra"] as Array).append(p)
	return by_root.values()


## union-find find（带路径压缩）。
static func _uf_find(parent: Array, x: int) -> int:
	var r: int = x
	while parent[r] != r:
		r = parent[r]
	while parent[x] != r:
		var nx: int = parent[x]
		parent[x] = r
		x = nx
	return r


func _deduce_l3(board: Board) -> Dictionary:
	var safe: Array[Vector2i] = []
	var mine: Array[Vector2i] = []
	var cs := _cs_from_board(board)
	var frontier := _cs_frontier_sorted(cs)
	for c in frontier:
		if _l3_nodes > L3_BUDGET:
			stats.l3_budget_hits += 1
			break
		if _refute(cs, c, true, l3_depth):
			if not safe.has(c):
				safe.append(c)
			continue
		if _refute(cs, c, false, l3_depth):
			if not mine.has(c):
				mine.append(c)
	return {"safe": safe, "mine": mine}


## 假设 c 为雷/安全，传播到不动点，检测矛盾。返回 true = 假设导致矛盾（假设为假）。
func _refute(cs: Dictionary, c: Vector2i, as_mine: bool, depth: int) -> bool:
	_l3_nodes += 1
	var snap := _cs_snapshot(cs)
	if as_mine:
		_cs_assume_mine(cs, c)
	else:
		_cs_assume_safe(cs, c)

	if _cs_infeasible(cs):
		_cs_restore(cs, snap)
		return true
	# 传播到不动点（L0/L1 确定性传播）
	var rounds := 0
	while _cs_l01(cs):
		rounds += 1
		if rounds > 128:
			break
		if _cs_infeasible(cs):
			_cs_restore(cs, snap)
			return true
	if _cs_infeasible(cs):
		_cs_restore(cs, snap)
		return true

	# 深度 2：第一层假设未矛盾，对新 frontier 再做一层
	if depth > 1:
		for c2 in _cs_frontier_sorted(cs):
			if _refute(cs, c2, true, depth - 1):
				_cs_restore(cs, snap)
				return true
			if _refute(cs, c2, false, depth - 1):
				_cs_restore(cs, snap)
				return true

	_cs_restore(cs, snap)
	return false


# ───────── 约束状态（独立于 board 的真实雷位） ─────────

func _cs_from_board(board: Board) -> Dictionary:
	var size := board.grid.size()
	var need := {}
	var mine := {}
	var hidden := {}
	for y in size.y:
		for x in size.x:
			var p := Vector2i(x, y)
			var c := board.grid.get_cell(p)
			if c.state == Cell.State.FLAGGED:
				mine[p] = true
			elif c.state == Cell.State.REVEALED:
				var con: Dictionary = c.get_player_constraint()
				if con.get("type", "") == "equality" and (con.get("value", 0) is int):
					need[p] = con["value"]
			else:
				hidden[p] = true
	# 已定雷对邻线索的贡献从 need 扣减（按线索权重，DIST_SUM 正交 1 对角 2）
	for m in mine:
		for q in _window(m, size):
			if need.has(q):
				need[q] -= _clue_weight(q, m)
	return {"need": need, "mine": mine, "hidden": hidden, "size": size, "M": board.total_mines}


func _cs_snapshot(cs: Dictionary) -> Dictionary:
	return {"need": (cs["need"] as Dictionary).duplicate(),
			"mine": (cs["mine"] as Dictionary).duplicate(),
			"hidden": (cs["hidden"] as Dictionary).duplicate()}


func _cs_restore(cs: Dictionary, snap: Dictionary) -> void:
	cs["need"] = snap["need"]
	cs["mine"] = snap["mine"]
	cs["hidden"] = snap["hidden"]


func _cs_assume_mine(cs: Dictionary, c: Vector2i) -> void:
	(cs["hidden"] as Dictionary).erase(c)
	(cs["mine"] as Dictionary)[c] = true
	for q in _window(c, cs["size"]):
		var need: Dictionary = cs["need"]
		if need.has(q):
			need[q] -= _clue_weight(q, c)


func _cs_assume_safe(cs: Dictionary, c: Vector2i) -> void:
	(cs["hidden"] as Dictionary).erase(c)


## 矛盾检测：①某线索雷数超界 ②某线索剩余雷放不下 ③全局雷数超界/放不下。
func _cs_infeasible(cs: Dictionary) -> bool:
	var size: Vector2i = cs["size"]
	var need: Dictionary = cs["need"]
	var hidden: Dictionary = cs["hidden"]
	var mine: Dictionary = cs["mine"]
	for p in need:
		var v: int = need[p]
		if v < 0:
			return true
		var hn := 0
		for n in _window(p, size):
			if hidden.has(n):
				hn += _clue_weight(p, n)
		if hn < v:
			return true
	var m: int = mine.size()
	var h: int = hidden.size()
	if m > cs["M"]:
		return true
	if m + h < cs["M"]:
		return true
	return false


## 约束版 L0/L1：need==0 ⇒ 未知邻全安全；need==未知邻数 ⇒ 未知邻全雷。
func _cs_l01(cs: Dictionary) -> bool:
	var size: Vector2i = cs["size"]
	var need: Dictionary = cs["need"]
	var hidden: Dictionary = cs["hidden"]
	var mine: Dictionary = cs["mine"]
	var changed := false
	for p in need.keys():
		var v: int = need[p]
		var hn: Array = []
		var hn_wsum := 0
		for n in _window(p, size):
			if hidden.has(n):
				hn.append(n)
				hn_wsum += _clue_weight(p, n)
		if hn.is_empty():
			continue
		if v == 0:
			for n in hn:
				hidden.erase(n)
				changed = true
		elif v == hn_wsum:
			for n in hn:
				hidden.erase(n)
				mine[n] = true
				for q in _window(n, size):
					if need.has(q):
						need[q] -= _clue_weight(q, n)
				changed = true
	return changed


func _cs_frontier_sorted(cs: Dictionary) -> Array:
	var size: Vector2i = cs["size"]
	var need: Dictionary = cs["need"]
	var hidden: Dictionary = cs["hidden"]
	var f := {}
	for p in need:
		for n in _window(p, size):
			if hidden.has(n) and not f.has(n):
				f[n] = true
	var arr: Array = f.keys()
	arr.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	return arr


# ───────────────────────── 工具 ─────────────────────────

func _count_revealed(board: Board) -> int:
	var size := board.grid.size()
	var n := 0
	for y in size.y:
		for x in size.x:
			if board.grid.get_cell(Vector2i(x, y)).state == Cell.State.REVEALED:
				n += 1
	return n


## 收集玩家视角约束集（与 SolverPerfectPlayer._collect_revealed 同语义）。
func collect_revealed(board: Board) -> Dictionary:
	var revealed := {}
	var size := board.grid.size()
	for y in size.y:
		for x in size.x:
			var pos := Vector2i(x, y)
			if board.grid.get_cell(pos).state == Cell.State.REVEALED:
				revealed[pos] = board.get_player_constraint(pos)
	return revealed
