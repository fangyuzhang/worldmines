class_name RepairSuggest
extends RefCounted

## 自动修复建议（编辑器 P1 内核，2026-10-03）。
##
## 【职责】给定一份 `EditorDoc`，当 `EditorVerify` 判定"可能需要猜测"（死局）时，
## 给出 1~3 条**可执行且已自证有效**的单步修法（挪一颗雷 / 加一条初始线索）。
## 「有效」的定义：把该修法在**文档副本**上试执行后，用既有 `EditorVerify.verify_islands`
## 重跑得到的结论必须是"无需猜测可解"（`STATE_NO_GUESS`）。
##
## 【三条硬纪律】
##   1) **绝不动原文档**：只读 `doc.snapshot()` 造副本，所有试执行都发生在副本上
##      ⇒ 调用方可用 `doc.snapshot()` 前后比对自证"建议没悄悄改盘"。
##   2) **不许编建议**：复核不过的候选直接丢弃；一条都过不了 ⇒ `ok=false` + 可读原因。
##   3) **不许谎称最优**：候选搜索有硬上限；未穷尽 ⇒ `exhaustive=false`，如实说"没搜完"。
##
## 【为什么复用 verify_islands 而不是自写判据】与验证面板同一套判据，避免出现
## "建议说修好了、验证面板仍报需猜"的分歧。`core/editor_verify.gd` 是本仓唯一权威。
##
## 【候选空间（`exhaustive=true` 时的完整含义）】只搜"单步、且发生在需猜岛内部"的修法：
##   · `add_clue`：把该岛任一「隐藏安全格」加入初始翻开（只加线索，不挪雷）；
##   · `move_mine`：把该岛任一雷挪到该岛任一「隐藏安全格」。
## 明确**不搜**（故别把 exhaustive 当"全解空间已穷尽"）：跨岛挪雷 / 多步组合修法 /
## 增删雷数 / 改声明雷数 / 非需猜岛上的改动——它们要么改变岛雷数、要么已超出"局部修法"。

const KIND_MOVE_MINE := "move_mine"
const KIND_ADD_CLUE := "add_clue"

## 候选空间的原始组合数上限：与 `core/brute_force_oracle.gd:19 MAX_COMBOS` 同口径的
## "宁可不搜，不许硬算"。超过即标记 `exhaustive=false`。
const MAX_PAIR_EVALS := 2_000_000

## 真正试执行的候选条数上限（每条都要跑一次 verify，必须小；与 `EditorDoc.MAX_CELL_BUDGET`
## 同属"编辑期不许卡住"的护栏）。可用 opts["max_candidates"] 覆盖（测试用来确定性触发超限）。
const MAX_CANDIDATES := 64

const DEFAULT_TOTAL_BUDGET_MS := 8_000
const DEFAULT_VERIFY_BUDGET_MS := 2_000
const DEFAULT_PROBE_BUDGET_MS := 500

## 最多返回几条（需求写死 1~3；这里不许被 opts 抬到 3 以上）。
const MAX_SUGGESTIONS := 3


## 主入口。返回：
##   {ok, reason, suggestions: Array, exhaustive: bool, searched: int,
##    candidates: int, raw_pairs: int, state: String, stats: Dictionary}
## 每条 suggestion = `{kind, text, plan, verified: true, after: {state,label,reason,solutions,rounds}}`。
##   · `plan` 可判定地描述"对文档做什么"（见 `apply_plan`），不是空话；
##   · `verified=true` 只在副本上重跑校验为「无需猜测可解」时才出现（验不过的条目根本不返回）。
## 状态语义：
##   · 已无需猜测可解 ⇒ ok=true、suggestions=[]（无需修复）；
##   · 需猜且找到修法   ⇒ ok=true、suggestions 1~3 条；
##   · 需猜但没找到/搜不完、矛盾、未知、文档非法 ⇒ ok=false + 可读原因。
static func suggest(doc: EditorDoc, opts: Dictionary = {}) -> Dictionary:
	if doc == null:
		return _fail("文档为空：没有可修复的盘")
	if doc.rows < 1 or doc.cols < 1:
		return _fail("棋盘尺寸非法（%dx%d）" % [doc.rows, doc.cols])
	if doc.cell_count() > EditorDoc.MAX_CELL_BUDGET:
		return _fail("格数 %d 超过编辑预算上限 %d：候选搜索已拒绝启动，请先把盘改小"
			% [doc.cell_count(), EditorDoc.MAX_CELL_BUDGET])
	if doc.mine_count() <= 0:
		return _fail("盘上还没有雷：先放雷再谈修复")

	var vopts := _verify_opts(opts)
	var base := _copy(doc)
	if base == null:
		return _fail("无法复制文档（快照恢复失败）：拒绝在原件上试执行")

	var v := EditorVerify.verify_islands(base, vopts)
	var state := str(v["state"])
	if state == EditorVerify.STATE_NO_GUESS:
		return {
			"ok": true, "reason": "当前盘无需修复：%s" % str(v["reason"]),
			"suggestions": [], "exhaustive": true, "searched": 0,
			"candidates": 0, "raw_pairs": 0, "state": state, "stats": v["stats"],
		}
	if state == EditorVerify.STATE_CONTRADICTION:
		return _fail("存在逻辑矛盾：%s。挪雷 / 加线索改不了「根本无解」本身，请先按验证面板修矛盾"
			% str(v["reason"]), v)
	if state == EditorVerify.STATE_UNKNOWN:
		return _fail("验证未能得出结论（%s）：无法复核的建议不许给出（宁少而真）" % str(v["reason"]), v)

	# ---- 需要猜测：只在"需猜岛"内部生成本地单步候选 ----
	var islands: Array = (v["stats"] as Dictionary).get("islands", [])
	var problem := _problem_islands(islands)
	if problem.is_empty():
		return _fail("判定为需要猜测，但没能定位到具体是哪个岛：%s" % str(v["reason"]), v)

	var values: Dictionary = {}
	var pv := base.preview_clues()
	if bool(pv["ok"]):
		values = pv["values"]

	var max_candidates := clampi(int(opts.get("max_candidates", MAX_CANDIDATES)), 1, 100_000)
	var max_suggestions := clampi(int(opts.get("max_suggestions", MAX_SUGGESTIONS)), 1, MAX_SUGGESTIONS)
	var budget_ms := int(opts.get("total_budget_ms", DEFAULT_TOTAL_BUDGET_MS))
	var t0 := Time.get_ticks_msec()

	var raw := _collect_candidates(base, problem, values, max_candidates)
	var plans: Array = raw["plans"]
	var searched := 0
	var exhaustive := not bool(raw["truncated"])
	var suggestions: Array = []

	for plan in plans:
		if suggestions.size() >= max_suggestions:
			exhaustive = false   # 还有候选没试，"没搜完"必须如实说
			break
		if searched >= max_candidates:
			exhaustive = false
			break
		if Time.get_ticks_msec() - t0 > budget_ms:
			exhaustive = false
			break
		searched += 1
		var cand := _copy(doc)
		if cand == null or not _apply(cand, plan):
			continue
		var after := EditorVerify.verify_islands(cand, vopts)
		if str(after["state"]) != EditorVerify.STATE_NO_GUESS:
			continue
		suggestions.append(_suggestion(plan, after, values))

	if suggestions.is_empty():
		var why := "已试 %d 条单步候选（岛内挪雷 / 加线索），没有一条能通过复核" % searched
		if not exhaustive:
			why += "；候选搜索未穷尽（硬上限 %d 条 / 预算 %d ms），不代表不存在修法" % [max_candidates, budget_ms]
		why += "。请手工调整或缩小盘面。"
		return {
			"ok": false, "reason": why, "suggestions": [], "exhaustive": exhaustive,
			"searched": searched, "candidates": plans.size(), "raw_pairs": int(raw["raw_pairs"]),
			"state": state, "stats": v["stats"],
		}

	var reason := "给出 %d 条已复核有效的修法（在副本上重跑验证均判为「无需猜测可解」）" % suggestions.size()
	if not exhaustive:
		reason += "；候选搜索未穷尽（硬上限 %d 条 / 预算 %d ms），不代表只有这些" % [max_candidates, budget_ms]
	return {
		"ok": true, "reason": reason, "suggestions": suggestions, "exhaustive": exhaustive,
		"searched": searched, "candidates": plans.size(), "raw_pairs": int(raw["raw_pairs"]),
		"state": state, "stats": v["stats"],
	}


## 「一键应用」：把一条建议的 `plan` 落到**调用方明确给定的文档**上，并立即重跑校验。
## 【与 suggest() 的分工】suggest() 绝不动原文档（只在副本上试）；本函数是"用户真的点了应用"
## 时才调，会改 `doc`（这是需求「一键应用后自动重跑校验」的落点，UI 直接调即可）。
## 返回 `{ok, applied, reason, verify}`；ok=false 时 `doc` 未被修改（`_apply` 先校验后落笔，无半途状态）。
## 【落笔前先问 `can_apply()`】调用方若想"不适用就别留下副作用"，先调它；本函数自己也会走同一判据，
## 拒绝时 `reason` 就是那条**具体**原因（不再是笼统的"坐标越界 / 已被占用 / 类型未知"三合一）。
static func apply_plan(doc: EditorDoc, plan: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var why := _plan_reason(doc, plan)
	if why != "":
		return {"ok": false, "applied": false, "reason": "计划无法执行：%s" % why, "verify": {}}
	if not _apply(doc, plan):
		return {"ok": false, "applied": false,
			"reason": "计划无法执行：落笔时复核未通过（判据通过的瞬间之后文档被改动）", "verify": {}}
	var v := EditorVerify.verify_islands(doc, _verify_opts(opts))
	return {"ok": true, "applied": true, "reason": str(v["reason"]), "verify": v}


# ==================== 候选生成 ====================

## 从"需猜岛"生成确定性有序的单步候选：先加线索（更轻），后挪雷。
## 返回 `{plans, truncated, raw_pairs}`；`plans` 最多 cap 条，`truncated=true` 表示还有候选没列出。
static func _collect_candidates(base: EditorDoc, islands: Array, values: Dictionary, cap: int) -> Dictionary:
	var out: Array = []
	var seen := {}
	var truncated := false
	var raw_pairs := 0
	var mine_set := base.mine_set()
	var hidden_total := 0
	var moves_total := 0
	for isl in islands:
		var cells: Array[Vector2i] = []
		cells.assign((isl as Dictionary).get("cells", []))
		var hidden_safe: Array[Vector2i] = []
		var mines_here: Array[Vector2i] = []
		for p in cells:
			if mine_set.has(p):
				mines_here.append(p)
			elif not base.revealed.has(p):
				hidden_safe.append(p)
		hidden_total += hidden_safe.size()
		moves_total += mines_here.size() * hidden_safe.size()
		raw_pairs += hidden_safe.size() + mines_here.size() * hidden_safe.size()

		for p in hidden_safe:
			if out.size() > cap:
				break
			var val: Variant = values.get(p, null)
			_try_push(out, seen, {
				"op": KIND_ADD_CLUE,
				"cell": {"c": p.x, "r": p.y},
				"value": val,
			})
		var full := out.size() > cap
		if not full:
			for m in mines_here:
				for d in hidden_safe:
					if out.size() > cap:
						full = true
						break
					_try_push(out, seen, {
						"op": KIND_MOVE_MINE,
						"from": {"c": m.x, "r": m.y},
						"to": {"c": d.x, "r": d.y},
					})
				if full:
					break
		if full:
			truncated = true
			break

	if out.size() > cap:
		truncated = true
		out.resize(cap)
	# 原始组合数超过 2e6 熔断口径 ⇒ 即便恰好只列出 cap 条，也不许说"已穷尽"。
	if hidden_total + moves_total > MAX_PAIR_EVALS:
		truncated = true
	return {"plans": out, "truncated": truncated, "raw_pairs": raw_pairs}


static func _try_push(out: Array, seen: Dictionary, plan: Dictionary) -> void:
	var key := JSON.stringify(plan)
	if seen.has(key):
		return
	seen[key] = true
	out.append(plan)


static func _problem_islands(islands: Array) -> Array:
	var out: Array = []
	for it in islands:
		if str((it as Dictionary).get("state", "")) == EditorVerify.STATE_NEEDS_GUESS:
			out.append(it)
	return out


# ==================== 试执行 / 副本 ====================

## 一条 plan 对**这份**文档是否可执行 —— `""` = 可执行，否则**可读原因**。**纯读，不改任何东西**。
##
## 【为什么必须收口在这里】"这条修法现在还能不能用"是同一件事：`_apply()`（试执行）要先问它，
## UI 在落笔前也要先问它（否则会先记一步撤销再失败，或反过来"UI 说能修、core 拒绝"）。
## 2026-10-03 之前 UI 侧抄了一份同样 5 条判据 ⇒ 两份真相迟早漂移（改了一处忘另一处）。
## 现在两条路都走本函数：判据**只此一份**，UI 只负责显示 reason。
static func _plan_reason(doc: EditorDoc, plan: Dictionary) -> String:
	if doc == null:
		return "文档为空：没有可改的盘"
	var op := str(plan.get("op", ""))
	if op == KIND_ADD_CLUE:
		var c: Dictionary = plan.get("cell", {})
		var p := Vector2i(int(c.get("c", -1)), int(c.get("r", -1)))
		if not _plausible_target(doc, p):
			return "目标格 %s 不在盘上（越界或洞格）：加线索要挑盘内格" % str(p)
		# 隐藏安全格：不能是雷、也不能已经是初始翻开格（否则加了也没有新线索）
		if doc.mines.has(p):
			return "目标格 %s 已经是雷：加线索要挑**隐藏安全格**" % str(p)
		if doc.revealed.has(p):
			return "目标格 %s 已经是初始翻开格：加了不会带来新线索" % str(p)
		return ""
	if op == KIND_MOVE_MINE:
		var fd: Dictionary = plan.get("from", {})
		var td: Dictionary = plan.get("to", {})
		var a := Vector2i(int(fd.get("c", -1)), int(fd.get("r", -1)))
		var b := Vector2i(int(td.get("c", -1)), int(td.get("r", -1)))
		if not doc.mines.has(a):
			return "源格 %s 上没有雷：挪雷必须从雷格出发" % str(a)
		if not _plausible_target(doc, b):
			return "目标格 %s 不在盘上（越界或洞格）：挪雷的目标必须是盘内格" % str(b)
		if doc.mines.has(b) or doc.revealed.has(b):
			return "目标格 %s 已被雷或初始翻开格占用" % str(b)
		return ""
	return "未知修法：%s（可用：%s / %s）" % [op, KIND_ADD_CLUE, KIND_MOVE_MINE]


## 公开入口：这条 plan 现在还能不能用。**纯读**（不碰 `doc`，无副作用）⇒ 调用方可以
## "先问、再决定要不要记撤销步"。返回 `{ok, reason}`；`ok=false` 时 `reason` 必为非空可读原因。
static func can_apply(plan: Dictionary, doc: EditorDoc) -> Dictionary:
	var why := _plan_reason(doc, plan)
	if why != "":
		return {"ok": false, "reason": why}
	return {"ok": true, "reason": ""}


## 在副本上执行一条 plan。返回 false = 该计划对这份文档不合法（不落任何改动）。
## 【唯一判据】先问 `_plan_reason()`（与公开的 `can_apply()` 同一份），通过的才落笔。
static func _apply(cand: EditorDoc, plan: Dictionary) -> bool:
	var why := _plan_reason(cand, plan)
	if why != "":
		return false
	var op := str(plan.get("op", ""))
	if op == KIND_ADD_CLUE:
		var c: Dictionary = plan.get("cell", {})
		cand.revealed[Vector2i(int(c.get("c", -1)), int(c.get("r", -1)))] = null
		return true
	# 走到这里 `_plan_reason` 已保证：op 合法、源格有雷、目标格是未被占用的盘内格。
	var fd: Dictionary = plan.get("from", {})
	var td: Dictionary = plan.get("to", {})
	cand.mines.erase(Vector2i(int(fd.get("c", -1)), int(fd.get("r", -1))))
	cand.mines.append(Vector2i(int(td.get("c", -1)), int(td.get("r", -1))))
	return true


## 目标格是否可用（判据的一部分）：必须是**盘上真实存在的格**。
##
## 【2026-10-03 收口：判界只问网格】原实现按**包围盒**判界（`p.x < doc.cols and not obstacles`）——
## 与 `ui/level_editor.gd:_paste_selection` / `_cells_in` / 画布 的「问 `grid().in_board()`」是
## **两套口径**（同仓库同一 bug 类）。后果具体而真：形状盘（环形 annulus / 轮廓族）的「包围盒内、
## 但轮廓外或洞格」会被当成合法目标 ⇒ `can_apply` 说可用、`apply_plan` 真去写，落一条**不在盘上**的
## 初始翻开格（渲染找不到 Cell）。现在统一走网格：`in_board()` 同时覆盖"越界 / 障碍洞格 / 轮廓外格"，
## 无需再叠一层 `obstacles` 判断，判据只有一份。
static func _plausible_target(doc: EditorDoc, p: Vector2i) -> bool:
	if doc == null:
		return false
	return doc.grid().in_board(p)


## 深拷贝：只读既有 `snapshot()` / `restore()`（不改原文档），失败返回 null。
static func _copy(doc: EditorDoc) -> EditorDoc:
	var c := EditorDoc.new()
	if not c.restore(doc.snapshot()):
		return null
	return c


# ==================== 输出组装 ====================

static func _suggestion(plan: Dictionary, after: Dictionary, _values: Dictionary) -> Dictionary:
	var op := str(plan.get("op", ""))
	var text := ""
	if op == KIND_ADD_CLUE:
		var c: Dictionary = plan.get("cell", {})
		text = "给 (%d,%d) 格加初始线索 %s：该格当前未翻开，翻开后玩家一开局就能看到这个数字" % [
			int(c.get("c", -1)), int(c.get("r", -1)), _value_text(plan.get("value", null))]
	else:
		var f: Dictionary = plan.get("from", {})
		var t: Dictionary = plan.get("to", {})
		text = "把 (%d,%d) 的雷挪到 (%d,%d)：目标格当前为空且未翻开，挪雷后全盘可由演绎推出" % [
			int(f.get("c", -1)), int(f.get("r", -1)), int(t.get("c", -1)), int(t.get("r", -1))]
	var stats: Dictionary = after["stats"]
	return {
		"kind": op,
		"text": text,
		"plan": plan.duplicate(true),
		"verified": true,
		"after": {
			"state": str(after["state"]),
			"label": str(after["label"]),
			"reason": str(after["reason"]),
			"solutions": int(stats.get("solutions", -1)),
			"rounds": int(stats.get("rounds", 0)),
		},
	}


## 线索值可以是 int 或 Array（双值型），str() 都能读；null = 该格不携带线索。
static func _value_text(v: Variant) -> String:
	if v == null:
		return "（无数字）"
	if v is Array:
		var parts: Array[String] = []
		for e in v:
			parts.append(str(e))
		return "[%s]" % ",".join(parts)
	return str(v)


static func _verify_opts(opts: Dictionary) -> Dictionary:
	return {
		"total_budget_ms": int(opts.get("verify_budget_ms", DEFAULT_VERIFY_BUDGET_MS)),
		"probe_budget_ms": int(opts.get("probe_budget_ms", DEFAULT_PROBE_BUDGET_MS)),
	}


static func _fail(reason: String, v: Dictionary = {}) -> Dictionary:
	return {
		"ok": false, "reason": reason, "suggestions": [], "exhaustive": false,
		"searched": 0, "candidates": 0, "raw_pairs": 0,
		"state": str(v.get("state", "")), "stats": v.get("stats", {}),
	}
