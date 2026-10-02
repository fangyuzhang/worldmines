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


## 主入口。返回 `{state, label, reason, stats, issues}`。
## issues 非空 = 因为这个原因没能给出结论（UI 应在验证面板里逐条显示，不要只打控制台）。
static func verify(doc: EditorDoc, opts: Dictionary = {}) -> Dictionary:
	if doc == null:
		return _out(STATE_UNKNOWN, "文档为空", {}, [])
	if doc.rows < 1 or doc.cols < 1:
		return _out(STATE_UNKNOWN, "棋盘尺寸非法（%dx%d）" % [doc.rows, doc.cols], {}, [])

	var report := doc.validate()
	var blocking: Array = []
	for it in report["errors"]:
		var code := str((it as Dictionary)["code"])
		if not NON_BLOCKING_CODES.has(code):
			blocking.append(it)
	if not blocking.is_empty():
		return _out(STATE_UNKNOWN, "文档未通过校验（%d 条错误）：先修好再看结论" % blocking.size(), {}, blocking)

	var rule := doc.rule_object()
	if rule == null:
		return _out(STATE_UNKNOWN, "规则未解析：%s" % doc.rule_id_effective(), {}, [])
	var globals: Array = []
	for gid in doc.global_rule_ids:
		var g: Object = RuleRegistry.default().resolve(StringName(gid))
		if g == null:
			return _out(STATE_UNKNOWN, "全局规则未注册：%s" % gid, {}, [])
		globals.append(g)
	var topo: GridInterface = null
	var topo_dict := doc.topology()
	if not topo_dict.is_empty():
		var ag := AdjacencyGrid.new()
		ag.setup_from_topo(topo_dict)
		topo = ag

	var pv := doc.preview_clues()
	if not bool(pv["ok"]):
		return _out(STATE_UNKNOWN, "线索预览失败：%s" % str(pv["reason"]), {}, [])
	var values: Dictionary = pv["values"]

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
