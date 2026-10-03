# hotmap.gd —— 猜点热力图（编辑器差异化功能；纯逻辑、不依赖场景树）
#
# 【做什么】把「这一盘是怎么被一步步推出来的」变成逐格颜色数据：
#   · level      = 该格被**推理到**时的步序深度（初始翻开格 = 0；越晚推出越深），UI 据此上深浅；
#   · must_guess = 序贯演绎推不动、不得不盲猜的格（红点）；
#   · guess_index= 第几次盲猜（0 起，仅 must_guess 格有）。
#   · internal   = 该格属于某个复合格（复合格内部格共享同一个「逻辑一格」的值）。
#
# 【与求解器同口径（硬要求）】本模块**不发明**「难不难」的启发式：
#   · 可行性/四态结论直接取 `EditorVerify.verify()`（它本身复用 `RuleOracle` + `RuleCpSat`）；
#   · 深度与 must_guess 的推演循环复用**同一批**既有原语：
#       `RuleCpSat.find_forced_cells`（序贯 forced-cell，与 verify 的推演逐一相同）+
#       `RuleCpSat.find_solution`（推不动时取一条具体解、钉住第一个未定格的真值，记 1 次盲猜）。
#     这正是 `EditorVerify._count_guesses` 的确定性参考猜法（见 editor_verify.gd:459-507），
#     本模块只是把「每格在第几轮/第几次猜被定格」记下来 ⇒ 不引入任何新判据。
#   · 因此：must_guess 格数 > 0 ⟺ verify 判定「需要猜测」（在推演未因预算/轮数截断时）。
#
# 【诚实边界】推导不出来的格一律 `level = -1`（未知），并在 `reason` 里点明原因；
#   **绝不用默认值假装知道**。无 C# 后端、文档不合法、存在矛盾、验证未知 ⇒ ok=false。
#
# 【规模护栏】格数上限复用 `EditorDoc.MAX_CELL_BUDGET`（只读，= 5000）：超限直接拒绝，
#   不做全量热力（防 5000 格 × 每格多次 CP-SAT 探测把编辑器卡死）。
#
# 【复合格（MegaCell）】`core/mega_cell.gd` 目前**尚未接入 `EditorDoc`**（其文件末「集成点」
#   明说是后续切片）。故默认走**降级路径**：按基础格逐格计算，`reason` 注明「未接入、不假装支持」。
#   若调用方通过 `opts["mega"]` 传入 `MegaCell` 实例（或未来 `doc` 暴露 `mega_cells` 属性），
#   则把复合格聚合为逻辑一格：内部格共享同一 level / must_guess 并标记 `internal = true`。
#   ⚠ 求解器尚未把复合格当一格 ⇒ 该聚合只是「基础格热力图派生」，`reason` 会写清，不是按逻辑一格求解。
class_name HotMap
extends RefCounted

## 推导不出来的格：未知深度（UI 应显示为「未知」而不是最浅或最深）。
const LEVEL_UNKNOWN := -1

## 「未定格」哨兵（棋盘坐标非负，(-1,-1) 不可能是有效格）。
const INVALID_CELL := Vector2i(-1, -1)


## 主入口。返回
## `{ok: bool, cells: {Vector2i: {level, must_guess, [guess_index], internal}}, max_level: int,
##   reason: String, guess_count: int, state: String}`。
## `opts`（全部可选）：`max_rounds` / `total_budget_ms` / `probe_budget_ms`（默认同 `EditorVerify`）、
## `mega`（`MegaCell` 实例，见文件头「复合格」）。
static func build(doc: EditorDoc, opts: Dictionary = {}) -> Dictionary:
	if doc == null:
		return _refuse("文档为空，无法构建热力图")
	if doc.rows < 1 or doc.cols < 1:
		return _refuse("棋盘尺寸非法（%dx%d）" % [doc.rows, doc.cols])
	# 规模护栏：先算格数再建盘（`cell_count()` 是纯整数运算，不触发 grid()）。
	var cell_count := doc.cell_count()
	if cell_count > EditorDoc.MAX_CELL_BUDGET:
		return _refuse("预计 %d 格，超过热力图上限 %d（全量热力会长时间占住编辑器；请缩小盘面或合并格子）" % [
			cell_count, EditorDoc.MAX_CELL_BUDGET])
	if not RuleCpSat.available():
		return _refuse("无 C# 求解后端：无法做序贯 forced-cell 推演，热力图不可用（如实报未知，不用猜测代替）")

	# 权威结论：复用验证器的四态判定（它才是「可解/需猜」的口径）。
	var verdict := EditorVerify.verify(doc)
	var vstate := str(verdict["state"])
	if vstate == EditorVerify.STATE_CONTRADICTION or vstate == EditorVerify.STATE_UNKNOWN:
		return _refuse("验证未得出可分析结论（%s）：%s" % [
			EditorVerify.state_label(vstate), str(verdict["reason"])])

	# 复用验证器的公共前置（规则解析 / 全局规则 / 拓扑 / 线索预览），保证与 verify 同源。
	var prep := EditorVerify._prepare(doc)
	if not bool(prep["ok"]):
		return _refuse(str(prep["reason"]))
	var rule: Object = prep["rule"]
	var globals: Array = prep["globals"]
	var topo: GridInterface = prep["topo"]
	var values: Dictionary = prep["values"]

	var positions := EditorVerify._sorted_cells(doc.grid().all_positions())
	if positions.is_empty():
		return _refuse("棋盘没有任何可放雷的格（可能全被障碍占用）")

	# 起始状态与 verify 完全一致：文档给了 revealed 就用它，否则用编辑器建议开局。
	var active: Dictionary = {}
	if doc.revealed.is_empty():
		for p in doc.suggest_reveal():
			active[p] = values.get(p, null)
	else:
		for p in doc.revealed:
			active[p] = values.get(p, null)

	var total := doc.total_mines_for_solving()
	var max_rounds := int(opts.get("max_rounds", EditorVerify.DEFAULT_MAX_ROUNDS))
	var budget_ms := int(opts.get("total_budget_ms", EditorVerify.DEFAULT_TOTAL_BUDGET_MS))
	var probe_ms := int(opts.get("probe_budget_ms", EditorVerify.DEFAULT_PROBE_BUDGET_MS))

	var oracle := RuleOracle.new(rule, globals, Vector2i(doc.cols, doc.rows), total, topo)
	oracle.probe_budget_ms = probe_ms
	oracle.core_budget_ms = probe_ms
	var spec := oracle.build_spec(active, [])

	var cells: Dictionary = {}
	for p in positions:
		cells[p] = {"level": LEVEL_UNKNOWN, "must_guess": false, "internal": false}
	for p in active:
		if cells.has(p):
			(cells[p] as Dictionary)["level"] = 0   # 初始翻开格：深度 0（不是推理出来的）

	var known_mines: Array = []
	var round := 0
	var guesses := 0
	var stopped := ""
	var t0 := Time.get_ticks_msec()
	var guard := 0
	var guard_max := positions.size() + 2

	while true:
		if Time.get_ticks_msec() - t0 > budget_ms:
			stopped = "总预算 %d ms 耗尽" % budget_ms
			break
		if round >= max_rounds:
			stopped = "推演轮数达到上限 %d" % max_rounds
			break
		guard += 1
		if guard > guard_max:
			stopped = "推演步数超过护栏 %d" % guard_max
			break
		round += 1
		var f := RuleCpSat.find_forced_cells(spec)
		var safe := EditorVerify._pairs(f.get("safe", []))
		var forced_mines := EditorVerify._pairs(f.get("mine", []))
		var applied := 0
		for p in forced_mines:
			if not known_mines.has(p):
				known_mines.append(p)
				applied += 1
				if cells.has(p):
					(cells[p] as Dictionary)["level"] = round
		for p in safe:
			if not active.has(p):
				active[p] = values.get(p, 0)
				applied += 1
				if cells.has(p):
					(cells[p] as Dictionary)["level"] = round
		if active.size() + known_mines.size() >= positions.size():
			break   # 全盘推完
		if applied == 0:
			# 推不动 ⇒ 盲猜：取当前 spec 的一条具体解、钉住第一个未定格的真值
			#（与 `EditorVerify._count_guesses` 同法；这是确定性参考次数，非数学最优）。
			var pick := _first_unresolved(positions, active, known_mines)
			if pick == INVALID_CELL:
				stopped = "无可继续的格（推导中断）"
				break
			var sol := RuleCpSat.find_solution(spec)
			if sol.is_empty():
				stopped = "找不到可行解（与验证结论不一致）"
				break
			var mine_set: Dictionary = {}
			for mm in sol:
				mine_set[mm] = true
			if cells.has(pick):
				var rec: Dictionary = cells[pick]
				rec["level"] = round
				rec["must_guess"] = true
				rec["guess_index"] = guesses
			if mine_set.has(pick):
				known_mines.append(pick)
			else:
				active[pick] = values.get(pick, null)
			guesses += 1
		spec = oracle.build_spec(active, known_mines)

	var resolved := active.size() + known_mines.size()
	var unknown_count := positions.size() - resolved
	var max_level := 0
	for p in cells:
		var l := int((cells[p] as Dictionary)["level"])
		if l > max_level:
			max_level = l

	var mega_note := _apply_mega_if_any(doc, opts, cells)

	var parts: Array[String] = []
	parts.append("序贯演绎 %d 轮：%d/%d 格推出、%d 格需盲猜" % [round, resolved, positions.size(), guesses])
	parts.append("与验证器口径一致（%s）" % EditorVerify.state_label(vstate))
	if unknown_count > 0:
		var why := stopped
		if why == "":
			why = "推导中断"
		parts.append("%d 格未能推出（level=-1）：%s" % [unknown_count, why])
	var reason := "；".join(parts) + mega_note

	return {
		"ok": true,
		"cells": cells,
		"max_level": max_level,
		"reason": reason,
		"guess_count": guesses,
		"state": vstate,
	}


# ==================== 复合格（MegaCell）====================

## 复合格聚合。返回要追加到 `reason` 的说明（无复合格时说明降级行为）。
static func _apply_mega_if_any(doc: EditorDoc, opts: Dictionary, cells: Dictionary) -> String:
	var mega := _mega_registry(doc, opts)
	if mega == null or mega.count() == 0:
		return "；复合格未接入：按基础格逐格计算，未做「逻辑一格」聚合（不假装支持）"
	var n := _apply_mega(cells, mega)
	return "；复合格：%d 个已聚合为逻辑一格（内部格共享同一值并标记 internal）；⚠ 求解器尚未把复合格当一格，本聚合由基础格热力图派生，非按逻辑一格求解" % n


## 取复合格注册表：优先 `opts["mega"]`，其次 `doc` 上未来可能出现的 `mega_cells` 属性。
static func _mega_registry(doc: EditorDoc, opts: Dictionary) -> MegaCell:
	var m: Variant = opts.get("mega", null)
	if m is MegaCell:
		return m
	for prop in doc.get_property_list():
		if str((prop as Dictionary).get("name", "")) == "mega_cells":
			var v: Variant = doc.get("mega_cells")
			if v is MegaCell:
				return v
			break
	return null


## 把同一复合格内的基础格聚成一个「逻辑一格」的值：
## level 取成员最大（最晚被推出）；must_guess = 任一成员需猜；guess_index 取最小者（最先猜）。
## 仅改入参 `cells`，返回被聚合的复合格个数。
static func _apply_mega(cells: Dictionary, registry: MegaCell) -> int:
	var groups: Dictionary = {}
	for p in cells:
		var oid := registry.owner_of(p)
		if oid == 0:
			continue
		if not groups.has(oid):
			groups[oid] = []
		(groups[oid] as Array).append(p)
	for oid in groups:
		var members: Array = groups[oid]
		var lvl := LEVEL_UNKNOWN
		var mg := false
		var gi := -1
		for p in members:
			var rec: Dictionary = cells[p]
			var l := int(rec["level"])
			if l > lvl:
				lvl = l
			if bool(rec.get("must_guess", false)):
				mg = true
				var gidx := int(rec.get("guess_index", -1))
				if gi < 0 or (gidx >= 0 and gidx < gi):
					gi = gidx
		for p in members:
			var rec2: Dictionary = cells[p]
			rec2["level"] = lvl
			rec2["must_guess"] = mg
			rec2["internal"] = true
			if mg and gi >= 0:
				rec2["guess_index"] = gi
	return groups.size()


# ==================== 内部工具 ====================

static func _first_unresolved(positions: Array[Vector2i], active: Dictionary, known_mines: Array) -> Vector2i:
	for p in positions:
		if not active.has(p) and not known_mines.has(p):
			return p
	return INVALID_CELL


static func _refuse(reason: String) -> Dictionary:
	return {
		"ok": false,
		"cells": {},
		"max_level": 0,
		"reason": reason,
		"guess_count": 0,
		"state": "refused",
	}
