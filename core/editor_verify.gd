class_name EditorVerify
extends RefCounted

## 编辑器逻辑验证器（编辑器 P1 内核，2026-10-01）。
##
## 【四态语义】编辑器只需要回答四个问题，多一个都不答（答不了就如实说"未知"）：
##   * 存在逻辑矛盾：没有任何雷分布能满足已揭示线索 + 声明的总雷数（`is_feasible` 为假）
##   * 无需猜测可解：从初始状态起，**序贯演绎**（每轮问"哪些格被强制"）能推完全盘
##   * 可能需要猜测：演绎到某轮再无强制格，而盘上仍有未定格
##   * 未知：文档自身没通过校验 / 缺少后端 / 触达预算上限 —— **绝不用"猜"代替结论**
##
## 【为什么复用现有求解器】`RuleOracle.build_spec` + `RuleCpSat` 三接口
##（is_feasible / count_solutions / find_forced_cells）已经是本仓生成期与提示器共用的同一套判据，
## 编辑器另写一套只会产出"编辑器说可解、生成器说不可解"的分歧。
##
## 【三重上限，保证不卡死（需求硬要求）】
##   ① 轮数上限（max_rounds，默认 64）；
##   ② 总墙钟预算（total_budget_ms，默认 8s）+ 每次 forced 探测预算（probe_budget_ms，默认 1.5s）；
##   ③ 无 C# 后端时的**组合数预检**：GDScript 回退是纯组合枚举且**没有内部节点上限**
##      （对比 `BruteForceOracle.MAX_COMBOS`），大棋盘上会长时间占住编辑器 ⇒ 先算 C(free, need)，
##      超过 `MAX_FALLBACK_COMBOS` 直接报"未知"，不启动枚举。
##
## 【不做 0 值泛洪】理由：0 格的邻格本身就是"被强制安全"，下一轮 `find_forced_cells` 会把它们找出来
## ⇒ 泛洪只是少几轮、不改变结论；而自己实现泛洪要复制一遍 `zero_safe_neighbors` 语义，容易与
## `Board` 分叉（本仓的历史坑）。**不泛洪是保守方向**（只会少报"无需猜测"，不会多报）。
##
## 【不注册规则】验证全程只用 `EditorDoc.rule_object()` 得到的内存实例 + IR，
## 不进 `RuleRegistry` 全局表 ⇒ 编辑器里随便改规则不会污染运行期注册表。

const STATE_NO_GUESS := "no_guess"
const STATE_NEEDS_GUESS := "needs_guess"
const STATE_CONTRADICTION := "contradiction"
const STATE_UNKNOWN := "unknown"

const DEFAULT_MAX_ROUNDS := 64
const DEFAULT_TOTAL_BUDGET_MS := 8_000
const DEFAULT_PROBE_BUDGET_MS := 1_500

## 无 C# 后端时允许启动组合枚举的上限（与 `core/brute_force_oracle.gd:19 MAX_COMBOS` 同口径）。
const MAX_FALLBACK_COMBOS := 2_000_000

## 按岛验证时，单岛的**最低**墙钟预算：总预算 8s 不许因多岛而翻倍，
## 但每个岛都该有机会出结论（哪怕只剩 1ms 总余额），故设下限。
const ISLAND_MIN_BUDGET_MS := 500

## 允许"文档校验不通过但仍继续验证"的错误码：声明雷数不符本身就是要验证器给结论的那类问题
##（否则用户会陷入"报错说矛盾、验证器又拒绝验证"的死循环）。
const NON_BLOCKING_CODES: Array[String] = ["declared_mismatch"]


static func state_label(state: String) -> String:
	match state:
		STATE_NO_GUESS:
			return "无需猜测可解"
		STATE_NEEDS_GUESS:
			return "可能需要猜测"
		STATE_CONTRADICTION:
			return "存在逻辑矛盾"
		_:
			return "未知（未能得出结论）"


## 公共前置：文档校验 → 规则解析 → 拓扑 → 线索预览。verify() 与 verify_islands() 共用，
## 保证"两条路径对同一份文档给出同一类拒绝理由"。
## 返回 {ok, state, reason, issues, rule, globals, topo(GridInterface), values(Dictionary)}。
static func _prepare(doc: EditorDoc) -> Dictionary:
	if doc == null:
		return {"ok": false, "state": STATE_UNKNOWN, "reason": "文档为空", "issues": []}
	if doc.rows < 1 or doc.cols < 1:
		return {"ok": false, "state": STATE_UNKNOWN, "reason": "棋盘尺寸非法（%dx%d）" % [doc.rows, doc.cols], "issues": []}

	var report := doc.validate()
	var blocking: Array = []
	for it in report["errors"]:
		var code := str((it as Dictionary)["code"])
		if not NON_BLOCKING_CODES.has(code):
			blocking.append(it)
	if not blocking.is_empty():
		return {"ok": false, "state": STATE_UNKNOWN,
			"reason": "文档未通过校验（%d 条错误）：先修好再看结论" % blocking.size(), "issues": blocking}

	var rule := doc.rule_object()
	if rule == null:
		return {"ok": false, "state": STATE_UNKNOWN, "reason": "规则未解析：%s" % doc.rule_id_effective(), "issues": []}
	var globals: Array = []
	for gid in doc.global_rule_ids:
		var g: Object = RuleRegistry.default().resolve(StringName(gid))
		if g == null:
			return {"ok": false, "state": STATE_UNKNOWN, "reason": "全局规则未注册：%s" % gid, "issues": []}
		globals.append(g)
	var topo: GridInterface = null
	var topo_dict := doc.topology()
	if not topo_dict.is_empty():
		var ag := AdjacencyGrid.new()
		ag.setup_from_topo(topo_dict)
		topo = ag

	var pv := doc.preview_clues()
	if not bool(pv["ok"]):
		return {"ok": false, "state": STATE_UNKNOWN, "reason": "线索预览失败：%s" % str(pv["reason"]), "issues": []}
	return {"ok": true, "rule": rule, "globals": globals, "topo": topo, "values": pv["values"]}


## 主入口。返回 `{state, label, reason, stats, issues}`。
## issues 非空 = 因为这个原因没能给出结论（UI 应在验证面板里逐条显示，不要只打控制台）。
static func verify(doc: EditorDoc, opts: Dictionary = {}) -> Dictionary:
	var prep := _prepare(doc)
	if not bool(prep["ok"]):
		return _out(str(prep["state"]), str(prep["reason"]), {}, prep["issues"])

	var rule: Object = prep["rule"]
	var globals: Array = prep["globals"]
	var topo: GridInterface = prep["topo"]
	var values: Dictionary = prep["values"]

	# 起始状态：文档显式给的 revealed；没给就用编辑器的建议开局（0 值格 + 其邻格）。
	var active: Dictionary = {}
	var auto_start := false
	if doc.revealed.is_empty():
		auto_start = true
		for p in doc.suggest_reveal():
			active[p] = values.get(p, null)
	else:
		for p in doc.revealed:
			active[p] = values.get(p, null)

	var total := doc.total_mines_for_solving()
	var t0 := Time.get_ticks_msec()
	var max_rounds := int(opts.get("max_rounds", DEFAULT_MAX_ROUNDS))
	var budget_ms := int(opts.get("total_budget_ms", DEFAULT_TOTAL_BUDGET_MS))
	var oracle := RuleOracle.new(rule, globals, Vector2i(doc.cols, doc.rows), total, topo)
	oracle.probe_budget_ms = int(opts.get("probe_budget_ms", DEFAULT_PROBE_BUDGET_MS))
	oracle.core_budget_ms = oracle.probe_budget_ms
	var spec := oracle.build_spec(active, [])

	var stats := {
		"rounds": 0,
		"cells": doc.cell_count(),
		"total_mines": total,
		"revealed_start": active.size(),
		"auto_start": auto_start,
		"forced_safe": 0,
		"forced_mine": 0,
		"solutions": -1,
		"backend": "cpsat" if RuleCpSat.available() else "gdscript",
		"elapsed_ms": 0,
	}

	# ==== 廉价必要条件的矛盾预检（不调求解器） ====
	# 全部 active 格都被 `build_spec` 放进 safe_cells（约束为**非雷**），
	# 故雷只能落在剩下的 `cell_count - active.size()` 个格上；声明值超过这个上界即无解。
	# 为什么值得单独做：毫秒级抓住最常见的一类矛盾，且**不触发 C# 侧的 ERROR 日志**
	# —— `RuleSolver.IsFeasible` 对不可行实例会打 ERROR，而"不可行"是验证器的**正常结论**，
	# 不该在 GUT 的 Unexpected Errors 与发行版日志里制造假 ERROR（2026-10-01 实测踩到）。
	var possible_mine_cells := doc.cell_count() - active.size()
	if total > possible_mine_cells:
		stats["elapsed_ms"] = Time.get_ticks_msec() - t0
		return _out(STATE_CONTRADICTION,
			"逻辑矛盾：声明总雷数 %d 超过可能的雷格数 %d（已揭示 %d 个安全格）⇒ 不存在满足条件的雷分布" % [
				total, possible_mine_cells, active.size()], stats, [])

	# ==== 无 C# 后端：只能数解（且必须先做组合数预检，否则会长时间占住编辑器） ====
	if not RuleCpSat.available():
		if not _fallback_cheap_enough(spec):
			return _out(STATE_UNKNOWN,
				"无 C# 后端：组合数超过 %d，GDScript 回退枚举会长时间占用（已拒绝启动），如实报未知" % MAX_FALLBACK_COMBOS,
				stats, [])
		var c := RuleCpSat.fallback_count(spec, 2)
		stats["solutions"] = c
		stats["elapsed_ms"] = Time.get_ticks_msec() - t0
		if c == 0:
			return _out(STATE_CONTRADICTION, "没有任何雷分布满足已揭示线索与声明的总雷数 %d" % total, stats, [])
		return _out(STATE_UNKNOWN,
			"无 C# 后端：可枚举出解（%d 档），但无法做序贯 forced-cell 推演 ⇒ 不给『可解/需猜』结论" % c,
			stats, [])

	# ==== 有后端：可行性 → 唯一性 → 序贯演绎 ====
	if not RuleCpSat.is_feasible(spec):
		stats["elapsed_ms"] = Time.get_ticks_msec() - t0
		return _out(STATE_CONTRADICTION,
			"没有任何雷分布满足已揭示线索与声明的总雷数 %d（线索/雷数互相矛盾）" % total, stats, [])
	var solutions := RuleCpSat.count_solutions(spec)
	stats["solutions"] = solutions

	var known_mines: Array = []
	var rounds := 0
	while true:
		var spent := Time.get_ticks_msec() - t0
		if spent > budget_ms:
			stats["rounds"] = rounds
			stats["elapsed_ms"] = spent
			return _out(STATE_UNKNOWN,
				"验证超时（预算 %d ms）：盘面太大或规则太复杂，已停下并如实报未知" % budget_ms, stats, [])
		if rounds >= max_rounds:
			stats["rounds"] = rounds
			stats["elapsed_ms"] = spent
			return _out(STATE_UNKNOWN, "推演轮数达到上限 %d，未得出结论" % max_rounds, stats, [])
		rounds += 1
		var f := RuleCpSat.find_forced_cells(spec)
		var safe := _pairs(f.get("safe", []))
		var forced_mines := _pairs(f.get("mine", []))
		var progressed := 0
		for p in forced_mines:
			if not known_mines.has(p):
				known_mines.append(p)
				progressed += 1
				stats["forced_mine"] = int(stats["forced_mine"]) + 1
		for p in safe:
			if not active.has(p):
				active[p] = values.get(p, 0)
				progressed += 1
				stats["forced_safe"] = int(stats["forced_safe"]) + 1
		if active.size() + known_mines.size() >= doc.cell_count():
			stats["rounds"] = rounds
			stats["elapsed_ms"] = Time.get_ticks_msec() - t0
			var note := "（初始状态取编辑器建议的开局）" if auto_start else "（初始状态取文档的 revealed）"
			return _out(STATE_NO_GUESS,
				"序贯演绎 %d 轮推完全盘 %s：%d 个安全格 + %d 颗雷；解数 %d" % [
					rounds, note, active.size(), known_mines.size(), solutions],
				stats, [])
		if progressed == 0:
			break
		spec = oracle.build_spec(active, known_mines)

	stats["rounds"] = rounds
	stats["elapsed_ms"] = Time.get_ticks_msec() - t0
	var left := doc.cell_count() - active.size() - known_mines.size()
	var why := "第 %d 轮已无强制格，还有 %d 个格推不出来" % [rounds, left]
	if auto_start:
		why += "（已按编辑器建议的开局起步）"
	return _out(STATE_NEEDS_GUESS, "%s ⇒ 玩家可能需要猜；当前解数 %d" % [why, solutions], stats, [])


# ==================== 按岛分别判定（W4：多岛硬要求） ====================

## 主入口（按岛）。返回结构与 `verify()` 相同，另加 `stats["islands"]`：
##   [{id, cells: Array[Vector2i](该岛格集合), cell_count, mines, state, label, reason,
##     rounds, left, guesses, solutions, forced_safe, forced_mine, revealed_start, elapsed_ms}]
##
## 【为什么能按岛拆】线索只依赖**邻接**（雷只影响自己邻格），而相邻格必属同一连通分量
## ⇒ 各岛的雷/线索互不影响，推理完全独立，整体结论就是各岛结论的合成。
## 【岛怎么切】BFS 走 `doc.grid().get_neighbors`——即文档自己的 dirs/wrap/拓扑；绝不另加 D8
##（那会把规则里本不连通的两块并成一个岛，给出"整盘可解"的假结论）。
## 【合成】任一岛矛盾 → 整体矛盾；任一岛未知 → 整体未知；全岛无需猜测 → 无需猜测；
## 否则 → 需要猜测，reason 逐岛列"第 N 号岛需要盲猜 K 次"。
## 【单岛】直接复用 `verify()`（行为与旧口径逐一一致），只补一条岛摘要。
static func verify_islands(doc: EditorDoc, opts: Dictionary = {}) -> Dictionary:
	var prep := _prepare(doc)
	if not bool(prep["ok"]):
		return _out(str(prep["state"]), str(prep["reason"]), {}, prep["issues"])

	var islands := _components(doc.grid())
	if islands.size() <= 1:
		var single := verify(doc, opts)
		var stats: Dictionary = single["stats"]
		stats["island_count"] = islands.size()
		stats["islands"] = [_island_summary(islands[0], single, doc)] if islands.size() == 1 else []
		return single

	var rule: Object = prep["rule"]
	var globals: Array = prep["globals"]
	var doc_topo: GridInterface = prep["topo"]
	var values: Dictionary = prep["values"]
	var auto_start := doc.revealed.is_empty()
	var suggested: Array[Vector2i] = []
	if auto_start:
		suggested = doc.suggest_reveal()
	var max_rounds := int(opts.get("max_rounds", DEFAULT_MAX_ROUNDS))
	var probe_ms := int(opts.get("probe_budget_ms", DEFAULT_PROBE_BUDGET_MS))
	var total_budget := int(opts.get("total_budget_ms", DEFAULT_TOTAL_BUDGET_MS))
	var t0 := Time.get_ticks_msec()
	var deadline := t0 + total_budget
	var results: Array = []
	for i in islands.size():
		var cells: Array[Vector2i] = islands[i]
		# 总预算不许翻倍：逐岛传**剩余额度**，单岛保底 ISLAND_MIN_BUDGET_MS。
		var used := Time.get_ticks_msec() - t0
		var left_budget := maxi(ISLAND_MIN_BUDGET_MS, total_budget - used)
		var r := _verify_island(doc, rule, globals, cells, values, auto_start, suggested,
			doc_topo, left_budget, probe_ms, max_rounds, deadline)
		r["id"] = i + 1
		results.append(r)
	return _synthesize_islands(doc, results, auto_start, Time.get_ticks_msec() - t0)


## 盘上的连通分量（BFS）。返回 `Array[Array[Vector2i]]`，按格数降序、同大小按最小格 (y,x) 升序
## ⇒ 岛号（1 起）稳定可复现。每个岛的格集合已按 (y,x) 排序（贪心取格要确定性）。
static func _components(g: GridInterface) -> Array:
	var seen := {}
	var comps: Array = []
	for p in g.all_positions():
		if seen.has(p):
			continue
		seen[p] = true
		var stack: Array[Vector2i] = [p]
		var comp: Array[Vector2i] = []
		while not stack.is_empty():
			var cur: Vector2i = stack.pop_back()
			comp.append(cur)
			for nb in g.get_neighbors(cur):
				if not seen.has(nb):
					seen[nb] = true
					stack.append(nb)
		comps.append(_sorted_cells(comp))
	comps.sort_custom(func(a: Array, b: Array) -> bool:
		if a.size() != b.size():
			return a.size() > b.size()
		var pa: Vector2i = a[0]
		var pb: Vector2i = b[0]
		if pa.y != pb.y:
			return pa.y < pb.y
		return pa.x < pb.x)
	return comps


static func _sorted_cells(cells: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for p in cells:
		out.append(p)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	return out


## 单个岛的序贯演绎。坐标系：整岛=沿用文档坐标/topology（与 verify() 逐位一致）；
## 拆岛=归一化到该岛包围盒（CP-SAT 只在岛内枚举，省算力）。
static func _verify_island(doc: EditorDoc, rule: Object, globals: Array, cells: Array[Vector2i],
		values: Dictionary, auto_start: bool, suggested: Array[Vector2i], doc_topo: GridInterface,
		budget_ms: int, probe_ms: int, max_rounds: int, deadline_ms: int) -> Dictionary:
	var cell_count := cells.size()
	var cell_set := {}
	for p in cells:
		cell_set[p] = true
	var is_whole := cells.size() == doc.grid().cell_count()
	var shift := Vector2i(0, 0)
	var topo: GridInterface = doc_topo
	var grid_size := Vector2i(doc.cols, doc.rows)
	if not is_whole:
		shift = Vector2i(1 << 30, 1 << 30)
		for p in cells:
			shift.x = mini(shift.x, p.x)
			shift.y = mini(shift.y, p.y)
		var local := _island_topology(cells, shift, doc.grid())
		topo = local
		grid_size = local.size()
	var mines_n := 0
	for m in doc.mines:
		if cell_set.has(m):
			mines_n += 1
	var active: Dictionary = {}
	if auto_start:
		for p in suggested:
			if cell_set.has(p):
				active[p - shift] = values.get(p, null)
	else:
		for p in doc.revealed:
			if cell_set.has(p):
				active[p - shift] = values.get(p, null)
	var res := {
		"id": 0, "cells": cells, "cell_count": cell_count, "mines": mines_n,
		"state": STATE_UNKNOWN, "label": "", "reason": "",
		"rounds": 0, "left": -1, "guesses": 0, "solutions": -1,
		"forced_safe": 0, "forced_mine": 0, "revealed_start": active.size(),
	}

	var t0 := Time.get_ticks_msec()
	var oracle := RuleOracle.new(rule, globals, grid_size, mines_n, topo)
	oracle.probe_budget_ms = probe_ms
	oracle.core_budget_ms = probe_ms
	var spec := oracle.build_spec(active, [])

	# 廉价矛盾预检（与 verify 同口径）：雷只能落在非激活格上。
	var possible_mine_cells := cell_count - active.size()
	if mines_n > possible_mine_cells:
		return _finish(res, STATE_CONTRADICTION,
			"本岛雷数 %d 超过可能的雷格数 %d" % [mines_n, possible_mine_cells], Time.get_ticks_msec() - t0)

	if not RuleCpSat.available():
		if not _fallback_cheap_enough(spec):
			return _finish(res, STATE_UNKNOWN,
				"无 C# 后端：本岛组合数超过 %d，如实报未知" % MAX_FALLBACK_COMBOS, Time.get_ticks_msec() - t0)
		var c := RuleCpSat.fallback_count(spec, 2)
		res["solutions"] = c
		if c == 0:
			return _finish(res, STATE_CONTRADICTION,
				"没有任何雷分布满足本岛线索与雷数 %d" % mines_n, Time.get_ticks_msec() - t0)
		return _finish(res, STATE_UNKNOWN,
			"无 C# 后端：可枚举出解，但无法做序贯 forced-cell 推演", Time.get_ticks_msec() - t0)

	if not RuleCpSat.is_feasible(spec):
		return _finish(res, STATE_CONTRADICTION,
			"没有任何雷分布满足本岛线索与雷数 %d" % mines_n, Time.get_ticks_msec() - t0)
	var solutions := RuleCpSat.count_solutions(spec)
	res["solutions"] = solutions

	var known_mines: Array = []
	var rounds := 0
	while true:
		var spent := Time.get_ticks_msec() - t0
		if spent > budget_ms:
			res["rounds"] = rounds
			return _finish(res, STATE_UNKNOWN,
				"本岛验证超时（预算 %d ms）" % budget_ms, spent)
		if rounds >= max_rounds:
			res["rounds"] = rounds
			return _finish(res, STATE_UNKNOWN,
				"本岛推演轮数达到上限 %d" % max_rounds, spent)
		rounds += 1
		var f := RuleCpSat.find_forced_cells(spec)
		var safe := _pairs(f.get("safe", []))
		var forced_mines := _pairs(f.get("mine", []))
		var progressed := 0
		for p in forced_mines:
			if not known_mines.has(p):
				known_mines.append(p)
				progressed += 1
				res["forced_mine"] = int(res["forced_mine"]) + 1
		for p in safe:
			if not active.has(p):
				active[p] = values.get(p + shift, 0)
				progressed += 1
				res["forced_safe"] = int(res["forced_safe"]) + 1
		if active.size() + known_mines.size() >= cell_count:
			res["rounds"] = rounds
			return _finish(res, STATE_NO_GUESS,
				"序贯演绎 %d 轮推完本岛（%d 格 + %d 雷）" % [rounds, active.size(), known_mines.size()],
				Time.get_ticks_msec() - t0)
		if progressed == 0:
			break
		spec = oracle.build_spec(active, known_mines)

	res["rounds"] = rounds
	res["left"] = cell_count - active.size() - known_mines.size()
	res["guesses"] = _count_guesses(oracle, active, known_mines, values, shift, cells, deadline_ms)
	return _finish(res, STATE_NEEDS_GUESS,
		"本岛需要盲猜 %d 次（还有 %d 格推不出来）" % [int(res["guesses"]), int(res["left"])],
		Time.get_ticks_msec() - t0)


## 该岛格集合 + 岛内边 → 归一化后的 `AdjacencyGrid`（坐标减去 shift）。
static func _island_topology(cells: Array[Vector2i], shift: Vector2i, g: GridInterface) -> AdjacencyGrid:
	var positions: Array = []
	var neighbors: Dictionary = {}
	for p in cells:
		var lp := p - shift
		positions.append({"x": lp.x, "y": lp.y})
		var nbs: Array = []
		for nb in g.get_neighbors(p):
			var lnb := nb - shift
			nbs.append("%d,%d" % [lnb.x, lnb.y])
		neighbors["%d,%d" % [lp.x, lp.y]] = nbs
	var out := AdjacencyGrid.new()
	out.setup_from_topo({"positions": positions, "neighbors": neighbors})
	return out


## "是否需要猜测"的**参考次数**（确定性、可复现，非数学最优）：
## 能推就推；推不动时，从当前 spec 的一条具体解里取"第一个未定格"的真值钉住
##（安全⇒翻开，雷⇒标记），记 1 次盲猜，再继续推。给作者一个量级（"2 号岛要猜 3 次"）。
## 预算耗尽时返回已数到的次数（可能偏小）；无后端返回 -1。
static func _count_guesses(oracle: RuleOracle, active_in: Dictionary, known_in: Array,
		values: Dictionary, shift: Vector2i, cells: Array[Vector2i], deadline_ms: int) -> int:
	if not RuleCpSat.available():
		return -1
	var active := active_in.duplicate()
	var known: Array = known_in.duplicate()
	var guesses := 0
	var guard := 0
	while active.size() + known.size() < cells.size() and guard < cells.size() + 2:
		guard += 1
		if Time.get_ticks_msec() > deadline_ms:
			break
		var spec := oracle.build_spec(active, known)
		var f := RuleCpSat.find_forced_cells(spec)
		var progressed := false
		for p in _pairs(f.get("mine", [])):
			if not known.has(p):
				known.append(p)
				progressed = true
		for p in _pairs(f.get("safe", [])):
			if not active.has(p):
				active[p] = values.get(p + shift, 0)
				progressed = true
		if progressed:
			continue
		var sol := RuleCpSat.find_solution(spec)
		if sol.is_empty():
			break
		var mine_set := {}
		for m in sol:
			mine_set[m] = true
		var pick := Vector2i(-1, -1)
		for p in cells:
			var lp := p - shift
			if not active.has(lp) and not known.has(lp):
				pick = lp
				break
		if pick == Vector2i(-1, -1):
			break
		if mine_set.has(pick):
			known.append(pick)
		else:
			active[pick] = values.get(pick + shift, null)
		guesses += 1
	return guesses


## 各岛结论 → 整体结论 + 顶层 stats（与 verify() 同键，另加 island_count/islands）。
static func _synthesize_islands(doc: EditorDoc, results: Array, auto_start: bool, elapsed_ms: int) -> Dictionary:
	var contra: Array = []
	var unknown: Array = []
	var need: Array = []
	var no_guess_n := 0
	var max_rounds := 0
	var fs := 0
	var fm := 0
	var revealed_start := 0
	var sol := 1
	for r in results:
		var st := str((r as Dictionary)["state"])
		max_rounds = maxi(max_rounds, int(r["rounds"]))
		fs += int(r["forced_safe"])
		fm += int(r["forced_mine"])
		revealed_start += int(r["revealed_start"])
		var s := int(r["solutions"])
		if s < 0:
			sol = -1
		elif s >= 2 and sol >= 0:
			sol = 2
		if st == STATE_CONTRADICTION:
			contra.append(r)
		elif st == STATE_UNKNOWN:
			unknown.append(r)
		elif st == STATE_NEEDS_GUESS:
			need.append(r)
		else:
			no_guess_n += 1

	var state := STATE_NO_GUESS
	var reason := ""
	if not contra.is_empty():
		state = STATE_CONTRADICTION
		reason = "共 %d 个岛：%s 存在逻辑矛盾（%s）" % [
			results.size(), _island_ids_text(contra), str(contra[0]["reason"])]
	elif not unknown.is_empty():
		state = STATE_UNKNOWN
		reason = "共 %d 个岛：%s 的验证没能得出结论 —— 先修好再整体判定" % [
			results.size(), _island_ids_text(unknown)]
	elif not need.is_empty():
		state = STATE_NEEDS_GUESS
		var parts: Array[String] = []
		for r in need:
			parts.append("第 %d 号岛需要盲猜 %d 次（还有 %d 格推不出来）" % [
				int(r["id"]), int(r["guesses"]), int(r["left"])])
		reason = "%s ⇒ 玩家可能需要猜；共 %d 个岛：%d 个可解、%d 个需猜" % [
			"；".join(parts), results.size(), no_guess_n, need.size()]
	else:
		reason = "共 %d 个岛，全部无需猜测可解（各岛序贯演绎均推完）" % results.size()

	var stats := {
		"rounds": max_rounds,
		"cells": doc.cell_count(),
		"total_mines": doc.total_mines_for_solving(),
		"revealed_start": revealed_start,
		"auto_start": auto_start,
		"forced_safe": fs,
		"forced_mine": fm,
		"solutions": sol,
		"backend": "cpsat" if RuleCpSat.available() else "gdscript",
		"elapsed_ms": elapsed_ms,
		"island_count": results.size(),
		"islands": results,
	}
	return _out(state, reason, stats, [])


static func _island_ids_text(rs: Array) -> String:
	var parts: Array[String] = []
	for r in rs:
		parts.append("第 %d 号岛" % int(r["id"]))
	return "、".join(parts)


## 单岛盘的岛摘要（走 verify() 旧路径，故只有跨岛聚合量、没有逐岛 guesses）。
static func _island_summary(cells: Array[Vector2i], single: Dictionary, doc: EditorDoc) -> Dictionary:
	var stats: Dictionary = single["stats"]
	var st := str(single["state"])
	var forced := int(stats.get("forced_safe", 0)) + int(stats.get("forced_mine", 0))
	var reveal_start := int(stats.get("revealed_start", 0))
	var left := -1
	if st == STATE_NO_GUESS:
		left = 0
	elif st == STATE_NEEDS_GUESS:
		left = maxi(0, cells.size() - reveal_start - forced)
	var cell_set := {}
	for m in doc.mines:
		cell_set[m] = true
	var mines_n := 0
	for p in cells:
		if cell_set.has(p):
			mines_n += 1
	return {
		"id": 1, "cells": cells, "cell_count": cells.size(), "mines": mines_n,
		"state": st, "label": str(single["label"]), "reason": str(single["reason"]),
		"rounds": int(stats.get("rounds", 0)), "left": left,
		"guesses": 0 if st != STATE_NEEDS_GUESS else -1,
		"solutions": int(stats.get("solutions", -1)),
		"forced_safe": int(stats.get("forced_safe", 0)), "forced_mine": int(stats.get("forced_mine", 0)),
		"revealed_start": reveal_start, "elapsed_ms": int(stats.get("elapsed_ms", 0)),
	}


static func _finish(res: Dictionary, state: String, reason: String, elapsed: int) -> Dictionary:
	res["state"] = state
	res["label"] = state_label(state)
	res["reason"] = reason
	res["elapsed_ms"] = elapsed
	return res


## C# 侧返回的 [r,c] → 内部 Vector2i(c,r)（换算纪律与 `RuleCpSat.find_solution` 一致）。
static func _pairs(raw: Variant) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not (raw is Array):
		return out
	for e in raw:
		if e is Array and (e as Array).size() >= 2:
			var a: Array = e
			out.append(Vector2i(int(a[1]), int(a[0])))
	return out


## 无后端前的组合数预检：C(free, need) 是否在上限内。
## free/need 的算法必须与 `RuleCpSat.fallback_count` 一致（它按**包围盒**枚举，
## 而 `RuleOracle.build_spec` 会把拓扑洞格塞进 safe_cells ⇒ 洞格不会被当自由格，两边自洽）。
static func _fallback_cheap_enough(spec: Dictionary) -> bool:
	var rows := int(spec.get("rows", 0))
	var cols := int(spec.get("cols", 0))
	var total := int(spec.get("total_mines", -1))
	if total < 0 or rows <= 0 or cols <= 0:
		return false
	var known := (spec.get("mine_cells", []) as Array).size()
	var safe_n := (spec.get("safe_cells", []) as Array).size()
	var free := rows * cols - safe_n - known
	var need := total - known
	if need < 0 or free < need:
		return false
	var c := 1
	for i in need:
		# 组合数递推 C(n,k)=C(n,k-1)*(n-k+1)/k：这个顺序下整除恒成立（不是近似除法）
		@warning_ignore("integer_division")
		c = c * (free - i) / (i + 1)
		if c > MAX_FALLBACK_COMBOS:
			return false
	return true


static func _out(state: String, reason: String, stats: Dictionary, issues: Array) -> Dictionary:
	return {"state": state, "label": state_label(state), "reason": reason, "stats": stats, "issues": issues}
