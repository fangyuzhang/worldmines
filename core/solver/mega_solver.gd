# mega_solver.gd —— 复合格 → 单变量 求解映射（文档「三、形状系统 · 复合格」）
#
# 【为什么存在】`core/mega_cell.gd` 把一大片基础格合并成「逻辑一格」：显示一个数字、可放雷、
# 参与求解。若求解器仍按基础格逐格算，热力图/提示与玩家实际看到的「一格行为」就对不上。
# 本模块是**唯一**把复合格表达给求解器的入口：复合格 = **一个布尔变量**（雷数 0/1）。
#
# 【口径（本模块定义；勿含糊）】
#   · 逻辑单元 unit：一个复合格 = 一个单元（雷数 ≤ 1）；未被合并的基础格各自是一个单元。
#   · 变量位 anchor：每个单元在 rows×cols 规格里占一个坐标槽 = 其内部格的**规范序首格**
#     （`MegaCell.internal_cells()` 的第一个，即 (x,y) 字典序最小）。单元内的**非锚点格一律固定
#     为安全格**（进 spec 的 safe_cells），于是「单元是否有雷」恰由锚点变量表示 ⇒ 复合格 = 一个变量。
#   · 邻接：单元 X 的邻居 = X 的所有基础格在 `GridInterface` 下的邻格（**排除 X 自身区域**），
#     按「所属单元」去重后的单元集合。这正是 `MegaCell.adjacency()` 的「相邻基础格 → 单元」折算
#     （同一相邻复合格不论被命中几格，只算 1 个邻居）。
#   · 线索：已翻开单元 X 的数字 = X 的邻居单元中「含雷」的单元个数（每个邻居单元至多贡献 1）。
#     即「复合格邻域内的雷数计数」：相邻复合格不论把雷放在内部哪一格，都只算 1。
#   · 总雷数 total = **逻辑单元级**的雷数（不是基础格雷数）。
#
# 【与「展开成基础格」的一致性（硬要求 · 结论）】
#   设 M = 「复合格当一格」模型；U = 「按单元聚合口径展开成基础格」模型
#   （每基础格一个变量 + 每复合格区域「≤1 颗雷」 + 线索按**单元**求和）。则：
#     M 的解集 与 U 的解集（投影到「哪些单元含雷」）**逐点相等**。
#   证明（双射）：U 的任一解 → 令 m_Y = (单元 Y 的区域内有雷) ∈ {0,1}（区域 ≤1 保证是 0/1），
#   线索按单元求和的值不变 ⇒ 得到 M 的一个解；反向，M 的任一解 → 在「含雷的单元」里挑任一
#   基础格放雷、其余放 0 ⇒ 得到 U 的一个解，且投影回同一 m。两侧的唯一自由度是「那颗雷放在
#   区域内的哪一格」，而该自由度在逻辑层**不可观测**（数字只数单元）。
#   ⚠ **反例 / 边界**：若「展开」改用**逐基础格经典邻域计数**（相邻复合格按其内部「与线索相邻的
#   基础格」计数、不做单元去重），两模型**不一致**：同一个物理事实（某复合格有一雷）会因雷落在
#   区域内不同基础格而给出不同的数字。例：区域 A={(0,0),(1,0)} 有雷、线索格 (2,0)——雷在 (0,0)
#   时逐基础格计数 = 0，而「A 是逻辑一格」计数 = 1。故**唯一自洽的语义是上面的单元聚合口径**；
#   本模块只实现该口径，并拒绝无法保证一致的情形（非经典线索窗口 / 全局约束 / 脏嵌套）。
#
# 【不读真值做推理】`check_assignment` / `build_spec` / `find_forced` 只吃 build() 产出的模型；
#   模型里的线索值取玩家视角（缺省由引擎真值按上述聚合口径推导——与 `Board._compute_clues`
#   由真值推导基础格数字同性质）。求解结论本身不再触摸真实雷位。
class_name MegaSolver
extends RefCounted

## 逻辑单元类型。
const KIND_MEGA := "mega"
const KIND_BASE := "base"

## 复合格内雷数上限（与 MegaCell.DEFAULT_MINE_CAP 同口径）。
const MINE_CAP := 1

## 解集暴力枚举的锚点数上限（指数级；仅小盘 / 测试可用）。
const ENUM_ANCHOR_LIMIT := 16


# ==================== 映射：复合格 → 单变量 ====================

## 建立「复合格 → 单变量」模型。
## `opts`：
##   clue_values —— 可选 {Vector2i(锚点): int}：玩家视角**已显示**的逻辑线索值（优先采用）。
##   total_mines —— 可选 int：覆盖逻辑总雷数（缺省 = board.total_mines）。
## 返回 {ok, reason, size, units, anchors, anchor_of, unit_at, neighbors, clues,
##       revealed, non_anchor_cells, total_mines, mine_cap}；ok=false 时 reason 为拒绝原因。
static func build(board: Board, mega: MegaCell = null, opts: Dictionary = {}) -> Dictionary:
	if board == null or board.grid == null:
		return _fail("棋盘为空（board / grid 为 null）")
	# 只支持经典 8 邻 / 拓扑邻域：其余线索窗口（N4/SC/FR/CLOCK/HV/LOOP/DIST_SUM/自定义规则）
	# 的「窗口」不是本模块折算的单元邻域，硬做会得到与显示不一致的数字。
	if board.clue_variant != ClueEngine.Variant.CLASSIC or board.clue_variant2 >= 0 or board.rule_clue_id != "":
		return _fail("复合格求解目前只支持经典 8 邻线索（clue_variant=%d, clue_variant2=%d, rule='%s'）" % [
			board.clue_variant, board.clue_variant2, board.rule_clue_id])
	if board.constraint_variant >= 0 or board.constraint_variant2 >= 0 or not board.rule_global_ids.is_empty():
		return _fail("复合格求解暂不支持全局约束（constraint_variant=%d/%d, rules=%s）" % [
			board.constraint_variant, board.constraint_variant2, str(board.rule_global_ids)])
	if mega != null and not mega.conflicts().is_empty():
		return _fail("复合格注册表存在共格嵌套，拒绝在脏数据上求解：%s" % str(mega.conflicts()))

	var size: Vector2i = board.grid.size()
	var anchor_of := {}                 # 基础格 -> 单元锚点
	var unit_at := {}                   # 锚点 -> unit
	var units: Array = []
	var non_anchor: Array[Vector2i] = []

	if mega != null:
		for id in mega.ids():
			var cells: Array[Vector2i] = mega.internal_cells(id)
			if cells.is_empty():
				return _fail("复合格 #%d 内部格集合为空" % id)
			for c: Vector2i in cells:
				if not board.grid.in_board(c):
					return _fail("复合格 #%d 含越界基础格 %s" % [id, str(c)])
			var anchor: Vector2i = cells[0]   # internal_cells 为规范序（(x,y) 升序）⇒ 首格即锚点
			var u := {"kind": KIND_MEGA, "id": id, "anchor": anchor, "cells": cells}
			units.append(u)
			unit_at[anchor] = u
			for c2: Vector2i in cells:
				anchor_of[c2] = anchor
			for i in range(1, cells.size()):
				non_anchor.append(cells[i])

	for pos: Vector2i in board.grid.all_positions():
		if anchor_of.has(pos):
			continue   # 已被某个复合格占用 ⇒ 不再单独成单元
		var ub := {"kind": KIND_BASE, "id": 0, "anchor": pos, "cells": [pos]}
		units.append(ub)
		unit_at[pos] = ub
		anchor_of[pos] = pos

	var anchors: Array[Vector2i] = []
	for u2 in units:
		anchors.append(u2["anchor"])

	# 邻接：按「所属单元锚点」去重（复合格只算 1 个邻居）。
	var neighbors := {}
	for u3 in units:
		var a3: Vector2i = u3["anchor"]
		var cand: Array[Vector2i] = []
		if str(u3["kind"]) == KIND_MEGA:
			var adj: Dictionary = mega.adjacency(int(u3["id"]), board.grid)
			if not bool(adj.get("ok", false)):
				return _fail("复合格 #%d 邻接计算失败：%s" % [int(u3["id"]), str(adj.get("reason", ""))])
			cand.assign(adj["cells"])
		else:
			cand.assign(board.grid.get_neighbors(a3))
		var nbs := {}
		for b: Vector2i in cand:
			var a_nb: Vector2i = anchor_of.get(b, b)
			if a_nb == a3:
				continue          # 自身区域内的格不是邻居
			if not unit_at.has(a_nb):
				continue          # 防御：越界 / 拓扑洞格
			nbs[a_nb] = true
		var list: Array[Vector2i] = []
		for k in nbs:
			list.append(k)
		list.sort_custom(func(x: Vector2i, y: Vector2i) -> bool:
			return x.x < y.x or (x.x == y.x and x.y < y.y))
		neighbors[a3] = list

	# 已翻开单元：记安全；有真实线索值（非 ? / 非星号）的，按聚合口径给数字。
	var revealed: Array[Vector2i] = []
	var clues := {}
	var override: Dictionary = opts.get("clue_values", {})
	for u4 in units:
		var a4: Vector2i = u4["anchor"]
		var cell: Cell = board.grid.get_cell(a4)
		if cell == null or cell.state != Cell.State.REVEALED:
			continue
		revealed.append(a4)
		if override.has(a4):
			clues[a4] = int(override[a4])
			continue
		var con: Dictionary = board.get_player_constraint(a4)
		if str(con.get("type", "")) == "equality":
			# 不直接采信 con.value：它按基础格经典邻域算，含复合格时会与「一格」口径不符。
			clues[a4] = _clue_from_truth(board, unit_at, neighbors[a4])
		# interval（? 遮蔽）/ none（星号 / 无线索）：已翻开但无可判数字 ⇒ 只记安全。

	var total := int(opts.get("total_mines", board.total_mines))
	return {
		"ok": true,
		"reason": "",
		"size": size,
		"units": units,
		"anchors": anchors,
		"anchor_of": anchor_of,
		"unit_at": unit_at,
		"neighbors": neighbors,
		"clues": clues,
		"revealed": revealed,
		"non_anchor_cells": non_anchor,
		"total_mines": total,
		"mine_cap": MINE_CAP,
	}


# ==================== 求解（拼接既有原语）====================

## CP-SAT spec（见 `RuleOracle.build_spec` 口径 / `solver/RuleSolver.cs`）。
## 复合格 = 锚点变量；非锚点成员固定为安全格。`known_mines` = 已确证雷的**锚点**数组。
static func build_spec(model: Dictionary, known_mines: Array = []) -> Dictionary:
	if not bool(model.get("ok", false)):
		return {}
	var size: Vector2i = model["size"]
	var rows := size.y
	var cols := size.x
	var total := int(model["total_mines"])
	# 逐条线索一个 builder（无 aux）：sum(邻居锚点变量) == 数字。
	var clue_keys: Array = (model["clues"] as Dictionary).keys()
	clue_keys.sort_custom(func(x: Vector2i, y: Vector2i) -> bool:
		return x.x < y.x or (x.x == y.x and x.y < y.y))
	var neighbors: Dictionary = model["neighbors"]
	var clues: Array = []
	for a in clue_keys:
		var b := RuleBuilder.new(rows, cols, total)
		var vars: Array = []
		for nb: Vector2i in neighbors[a]:
			vars.append(b.cell_var_pos(nb))
		b.add_eq(b.sum(vars), int((model["clues"] as Dictionary)[a]))
		clues.append({"r": a.y, "c": a.x, "ir": b.constraints})
	# 安全格 = 已翻开单元锚点 + 复合格非锚点成员（非锚点固定 0 ⇒ 单元雷数只由锚点表示）。
	var safe: Array = []
	var revealed: Array[Vector2i] = []
	revealed.assign(model["revealed"])
	for a2: Vector2i in revealed:
		safe.append([a2.y, a2.x])
	var non_anchor: Array[Vector2i] = []
	non_anchor.assign(model["non_anchor_cells"])
	for c2: Vector2i in non_anchor:
		safe.append([c2.y, c2.x])
	var mine_cells: Array = []
	for m in known_mines:
		if m is Vector2i:
			mine_cells.append([m.y, m.x])
	return {
		"rows": rows,
		"cols": cols,
		"total_mines": total,
		"safe_cells": safe,
		"mine_cells": mine_cells,
		"clues": clues,
		"globals": [],
		"aux": [],
		"timeout_ms": 8000,
	}


## 给定「含雷的单元锚点集合」是否满足逻辑模型（纯逻辑判定，不读真实雷位）。
## `mine_anchors` 接受 Array[Vector2i] 或 {Vector2i: bool}；含未知锚点 / 数量不符即 false。
static func check_assignment(model: Dictionary, mine_anchors: Variant) -> bool:
	if not bool(model.get("ok", false)):
		return false
	var mines: Variant = _to_anchor_set(model, mine_anchors)
	if mines == null:
		return false
	if (mines as Dictionary).size() != int(model["total_mines"]):
		return false
	var revealed: Array[Vector2i] = []
	revealed.assign(model["revealed"])
	for a: Vector2i in revealed:
		if (mines as Dictionary).has(a):
			return false   # 已翻开单元必安全
	var neighbors: Dictionary = model["neighbors"]
	var clue_map: Dictionary = model["clues"]
	for a2 in clue_map:
		var got := 0
		for nb: Vector2i in neighbors[a2]:
			if (mines as Dictionary).has(nb):
				got += 1
		if got != int(clue_map[a2]):
			return false
	return true


## 暴力枚举全部满足逻辑模型的锚点雷集合（指数级；仅小盘 / 测试）。
static func enumerate_solutions(model: Dictionary) -> Array:
	var out: Array = []
	if not bool(model.get("ok", false)):
		return out
	var anchors: Array[Vector2i] = []
	anchors.assign(model["anchors"])
	var n := anchors.size()
	if n > ENUM_ANCHOR_LIMIT:
		push_error("MegaSolver.enumerate_solutions: 锚点数 %d 超过上限 %d（指数级枚举仅限小盘 / 测试）" % [n, ENUM_ANCHOR_LIMIT])
		return out
	var total := int(model["total_mines"])
	for mask in (1 << n):
		if _popcount(mask) != total:
			continue
		var mines: Array[Vector2i] = []
		for i in n:
			if (mask >> i) & 1 == 1:
				mines.append(anchors[i])
		if check_assignment(model, mines):
			out.append(mines)
	return out


## 唯一解计数代理：走 `RuleCpSat`（C# 优先，截断到 max_count；无 C# 时 GDScript 回退）。
static func count_solutions(model: Dictionary, known_mines: Array = [], max_count: int = 2) -> int:
	var spec := build_spec(model, known_mines)
	if spec.is_empty():
		return 0
	if RuleCpSat.available():
		return RuleCpSat.count_solutions(spec)
	return RuleCpSat.fallback_count(spec, max_count)


## 序贯 forced-cell 探测（与既有提示/验证同口径）。返回锚点集合
## {safe: Array[Vector2i], mine: Array[Vector2i]}；C# 不可用 ⇒ 双空（保守降级）。
static func find_forced(model: Dictionary, known_mines: Array = []) -> Dictionary:
	var safe_out: Array[Vector2i] = []
	var mine_out: Array[Vector2i] = []
	var spec := build_spec(model, known_mines)
	if spec.is_empty():
		return {"safe": safe_out, "mine": mine_out}
	var raw := RuleCpSat.find_forced_cells(spec)
	for s in raw.get("safe", []):
		safe_out.append(Vector2i(int(s[1]), int(s[0])))
	for m in raw.get("mine", []):
		mine_out.append(Vector2i(int(m[1]), int(m[0])))
	return {"safe": safe_out, "mine": mine_out}


# ==================== 引擎真值辅助（校验 / 测试 / 生成）====================

## 单元内是否含至少一颗雷（按基础格真值判定；复合格至多 1 颗，故 = 「该单元有雷」）。
static func unit_has_mine(board: Board, unit: Dictionary) -> bool:
	for c: Vector2i in (unit["cells"] as Array):
		if board.is_mine(c):
			return true
	return false


## 校验引擎真值与模型口径相容：单元雷数 ≤ 上限、逻辑总雷数 == total_mines。
## 返回 {ok, reasons: Array[String], logical_total}。
static func validate_ground_truth(board: Board, model: Dictionary) -> Dictionary:
	var reasons: Array = []
	if board == null or not bool(model.get("ok", false)):
		return {"ok": false, "reasons": ["模型不可用（build 未成功）"], "logical_total": -1}
	var logical_total := 0
	for u in model["units"]:
		var n := 0
		for c: Vector2i in (u["cells"] as Array):
			if board.is_mine(c):
				n += 1
		if n > MINE_CAP:
			reasons.append("单元锚点 %s 区域内含 %d 颗雷（上限 %d）：违反「复合格 = 逻辑一格」" % [
				str(u["anchor"]), n, MINE_CAP])
		if n >= 1:
			logical_total += 1
	if logical_total != int(model["total_mines"]):
		reasons.append("逻辑总雷数 %d ≠ 模型 total_mines %d" % [logical_total, int(model["total_mines"])])
	return {"ok": reasons.is_empty(), "reasons": reasons, "logical_total": logical_total}


# ==================== 内部工具 ====================

## 聚合口径线索值：邻居单元中「含雷」的单元数。
static func _clue_from_truth(board: Board, unit_at: Dictionary, neighbor_anchors: Array) -> int:
	var n := 0
	for a in neighbor_anchors:
		if unit_has_mine(board, unit_at[a]):
			n += 1
	return n


## 归一化含雷锚点集合；含未知锚点 / 类型不对 ⇒ null。
static func _to_anchor_set(model: Dictionary, mine_anchors: Variant) -> Variant:
	var anchors := {}
	for a in model["anchors"]:
		anchors[a] = true
	var out := {}
	if mine_anchors is Dictionary:
		for k in mine_anchors:
			if not (k is Vector2i) or not anchors.has(k):
				return null
			if bool(mine_anchors[k]):
				out[k] = true
	elif mine_anchors is Array:
		for k2 in mine_anchors:
			if not (k2 is Vector2i) or not anchors.has(k2):
				return null
			out[k2] = true
	else:
		return null
	return out


static func _popcount(v: int) -> int:
	var n := 0
	var x := v
	while x > 0:
		n += x & 1
		x = x >> 1
	return n


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
