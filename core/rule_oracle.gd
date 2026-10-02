# rule_oracle.gd —— 规则求值器（IR 黑盒判定 + C# 求解 spec 组装）
# 双后端的粘合层：
#   1. check()：IR 在具体雷分布下的黑盒求值 → 可直接当 BruteForceOracle /
#      SolverPerfectPlayer 的 check 回调（既有验证管线零改动接入）。
#   2. build_spec()：把「激活线索集 + 全局规则」组装成可序列化 spec，
#      交给 C# RuleSolver（OR-Tools CP-SAT）做快速唯一解计数。
class_name RuleOracle
extends RefCounted

var clue_rule: Object = null          # RulePlugin（KIND_CLUE）或 null
var global_rules: Array = []          # [RulePlugin（KIND_GLOBAL）]
var grid_size: Vector2i
## 拓扑（方案 A2）：非空 = 异形/邻接表棋盘，约束构造走拓扑邻域，洞格约束为非雷。
var topology: GridInterface = null

var _total_mines: int = -1
var _global_pkg: Dictionary = {}      # {"aux":[int..], "ir":[约束..]}
var _clue_cache: Dictionary = {}      # "x,y=值" -> pkg

## C# CP-SAT 搜索 worker 数（0 = 用 C# 默认；2026-09-24 起 C# 默认 **1=单线程确定性**，
## 原默认 4 已废弃——多线程搜索非确定（同 seed 不同盘）且有长尾挂死风险，见 solver/RuleSolver.cs）。
## 由 PuzzleGenerator.num_workers 透传。确需多线程提速请显式设 >1 并在调用处写明理由。
## 不影响强制格结论。
var num_workers: int = 0

## 【D2 2026-10-01】确定性判停（步数单位 ≈「参考机秒」）：>0 时下发
## `spec["max_deterministic_time"]`，CP-SAT 的**确定性工作量上限**即成为实际判停依据
##（C# 侧 `Params()` 已支持该键，见 solver/RuleSolver.cs:791-805 —— 无需改 C#）。
## 目的：把"判停点"从**墙钟**（受机器快慢/负载影响）换成**步数**（同 seed 同参数必停在同一处）
## ⇒ 修掉 R8「同 seed 重跑 clue_count 波动」。**0 = 现状**（墙钟为主 + det 2× 兜底）。
## ⚠ 打开会改变产出分布（原本能推完的盘可能被 det 上限截断）⇒ 必须先按 §24.7 的
##   服务器 A/B 协议验证（峰值直方图对照 + 黄金网 + 同 seed 两次重跑逐字节一致）再改默认值。
var deterministic_steps: float = 0.0

## ⛔ 【C4 2026-10-01：实测**不等价** ⇒ 默认关，禁止在未证明前启用】
## 做法：让 `build_spec` 复用 `clue_pkg/interval_pkg` 的缓存 IR（base=0 构建）并把 aux 编号整体平移。
## 动机：原先**每条线索、每轮都 new RuleBuilder 重建一遍**（实测占墙钟 5.8%，`_stage0b_out.txt:6`）。
## ⛔ 实测结论（黄金网独立 diff，`tools/_golden_diff.py` 对 `_golden_post_p0.jsonl`）：
##   `o4@6` seed1 变（max_complexity）、seed4 变（difficulty/profile/revealed/clue_count）、
##   `o4@8` seed1 变 ⇒ **产出被改变，不是逐字节等价** ⇒ 按 R01/R04 纪律**不得默认启用**
##   （与 ① `prune_probe_whitelist` 同一处置模式：保留实现与证据，默认关，避免后人重做同一实验）。
## 两个待查的怀疑点（谁先被排除就能救活这条 5.8%）：
##   ① 缓存包是用 `RuleBuilder.new(rows, cols, -1)` 构建的（total_mines = **-1**），
##      而原路径用 `_total_mines` ⇒ 若某条线索规则的约束真的读了构造期的 total_mines，两者不等价；
##   ② aux 前进量用 `pkg["aux"].size()` 代替 `b.next_aux_index()` ⇒ 若某规则创建 aux 时存在跳号/复用，
##      平移到本 spec 的编号就会与旧路径错位。
## 复活判据（必须全绿才可改默认）：把 ①② 对齐后**重跑黄金网全档逐字节对拍 0 差异**。
var _spec_clue_cache := false

## 累计求解预算（v4.0，挂死治理）：单次 Solve 有 max_time_in_seconds 上限，但
## **单次有界 ≠ 累计有界**——FindForcedCells 一次调用要做 O(自由格数) 次探测，
## MinimalForcedClueCount 最多 8 次 Solve，删线索又是 O(n) 条 × 序贯 O(轮) 次调用。
## 预算按「单次调用」计（耗尽即停，保守方向：未探测格不报强制、无 core 报 -1），
## 故不会因预算而产出坏关（R01/R02 不破），最多让该候选被拒。
## 调用方可按剩余墙钟收紧（见 PuzzleGenerator._solve_rules_stepwise 的 deadline_ms）；
## 0 = 关闭（回到旧行为，仅排查用）。
##
## 【默认值取 30s 的理由（2026-09-27 实测定标）】预算只应兜「病态」，**绝不该碰到正常调用**：
## 实测正常小盘一次 find_forced_cells 只需毫秒级（24 格 5×5 在 1ms 内已探完 3 格），
## 6×6 全盘 6 seed 的删线索总耗时才 0.4~100s（每次调用远低于 1s）。
## 而病态实例单次调用可达「自由格数 × 8s」（9×9 约 640s）且被删线索 O(n) 次放大成小时级。
## 30s = 正常调用的 30~100 倍余量（永不触发）+ 病态调用的 20 倍收敛（仍然有界）。
## ⚠ 调小此值会**降低关卡难度**（探测被截断 → 少报强制格 → 删线索变保守 → 保留更多线索），
## 属质量红线，除非有 A/B 证据否则不要动。
var probe_budget_ms: int = 30_000   # 一次 find_forced_cells 内所有 assumption 探测的累计上限
var core_budget_ms: int = 30_000    # 一次 minimal_clue_count_unsat 内 unsat_core 迭代的累计上限


func _init(p_clue_rule: Object = null, p_global_rules: Array = [], p_grid_size: Vector2i = Vector2i(0, 0), p_total_mines: int = -1, p_topology: GridInterface = null) -> void:
	clue_rule = p_clue_rule
	global_rules = p_global_rules.duplicate()
	grid_size = p_grid_size
	topology = p_topology
	_total_mines = p_total_mines
	var b := RuleBuilder.new(grid_size.y, grid_size.x, p_total_mines)
	if topology != null:
		b.set_topology(topology)
	for g in global_rules:
		g.build_global_constraints(b)
	_global_pkg = {"aux": _aux_ids(b.aux_vars), "ir": b.constraints}


static func _aux_ids(aux_vars: Array) -> Array:
	# P3：返回完整域信息（kind/lo/hi），供 eval_with_aux 做布尔 + 整数域回溯
	return aux_vars.duplicate(true)


## 单条线索的 IR 包（含 aux 编号），带缓存。
func clue_pkg(pos: Vector2i, value: Variant) -> Dictionary:
	var key := "%d,%d=%s" % [pos.x, pos.y, var_to_str(value)]
	if _clue_cache.has(key):
		return _clue_cache[key]
	var b := RuleBuilder.new(grid_size.y, grid_size.x, -1)
	if topology != null:
		b.set_topology(topology)
	clue_rule.build_clue_constraints(b, pos, value)
	var pkg := {"aux": _aux_ids(b.aux_vars), "ir": b.constraints}
	_clue_cache[key] = pkg
	return pkg


## 遮蔽（问号）格的 IR 包（区间约束），带缓存。
func interval_pkg(pos: Vector2i, lo: int, hi: int) -> Dictionary:
	var key := "%d,%d=[%d,%d]" % [pos.x, pos.y, lo, hi]
	if _clue_cache.has(key):
		return _clue_cache[key]
	var b := RuleBuilder.new(grid_size.y, grid_size.x, -1)
	if topology != null:
		b.set_topology(topology)
	clue_rule.build_interval_constraints(b, pos, lo, hi)
	var pkg := {"aux": _aux_ids(b.aux_vars), "ir": b.constraints}
	_clue_cache[key] = pkg
	return pkg


# ==== 【C4 2026-10-01】缓存包的 aux 编号平移 ====
# 为什么需要：clue_pkg/interval_pkg 的缓存包是用 `RuleBuilder.new(rows, cols, -1)`（**base=0**）
# 构建的，而 build_spec 里每条线索的 aux 必须落在**本 spec 全局唯一**的区间（next_base 顺延）
# ⇒ 复用缓存时必须整体平移。IR 的 aux 引用是紧凑节点 `{"t":"aux","i":id}`（core/cp_ir.gd:15），
# aux 域信息条目是 `{"i":id,"kind":…}` ⇒ 两种都只改 `i`，不动任何约束结构。
func _pkg_at(pkg: Dictionary, base: int) -> Dictionary:
	if base == 0:
		return pkg
	return {"aux": _shift_aux_i(pkg["aux"], base), "ir": _shift_aux_i(pkg["ir"], base)}


static func _shift_aux_i(x: Variant, delta: int) -> Variant:
	if x is Array:
		var arr: Array = []
		for e in x:
			arr.append(_shift_aux_i(e, delta))
		return arr
	if x is Dictionary:
		if str(x.get("t", "")) == "aux":
			return {"t": "aux", "i": int(x.get("i", 0)) + delta}
		var d: Dictionary = {}
		var is_domain: bool = x.has("i") and x.has("kind")   # aux 域信息条目（显式标注：x 是 Variant，`:=` 无法推断）
		for k in x:
			if is_domain and k == "i":
				d[k] = int(x[k]) + delta
			else:
				d[k] = _shift_aux_i(x[k], delta)
		return d
	return x


# ==== 黑盒判定（BruteForceOracle 兼容签名） ====

## mine_set（完整雷分布）是否满足全部已翻开线索 + 全局约束。
## revealed: pos -> {"type":"equality","value":线索值}（value=null 表示无线索格）。
func check(mine_set: Array[Vector2i], revealed: Dictionary, _grid_size: Vector2i) -> bool:
	var asg := {}
	for p in mine_set:
		asg[CPIR.cell_key(p.y, p.x)] = 1
	if clue_rule != null:
		for pos in revealed:
			var cd: Dictionary = revealed[pos]
			if str(cd.get("type", "equality")) == "interval":
				var pkg := interval_pkg(pos, int(cd["lo"]), int(cd["hi"]))
				if not CPIR.eval_with_aux(pkg["ir"], asg, pkg["aux"]):
					return false
			else:
				var value: Variant = cd.get("value", null)
				if value == null:
					continue
				var pkg := clue_pkg(pos, value)
				if not CPIR.eval_with_aux(pkg["ir"], asg, pkg["aux"]):
					return false
	if not _global_pkg["ir"].is_empty():
		if not CPIR.eval_with_aux(_global_pkg["ir"], asg, _global_pkg["aux"]):
			return false
	return true


func check_callable() -> Callable:
	return Callable(self, "check")


# ==== C# 求解 spec 组装 ====

## active: pos -> 线索值（当前激活的线索格）。known_mines: 已确认雷格。
## masked: pos -> Vector2i(lo, hi)（遮蔽格，用区间约束替代精确约束）。
## 返回的 spec 是纯 Dictionary/Array，可直接传 RuleSolver.CountSolutions。
func build_spec(active: Dictionary, known_mines: Array = [], masked: Dictionary = {}) -> Dictionary:
	var rows := grid_size.y
	var cols := grid_size.x
	# 全局规则（aux 从 0 起）
	var bg := RuleBuilder.new(rows, cols, _total_mines)
	if topology != null:
		bg.set_topology(topology)
	for g in global_rules:
		g.build_global_constraints(bg)
	var aux: Array = bg.aux_vars.duplicate(true)
	var next_base: int = bg.next_aux_index()
	# v3.0：线索规则的全局约束（如 O4 的 ∑w=k）——独立 builder，IR 并入 spec["globals"]。
	# 逐格 builder 与它不共享 aux；需要跨格的语义由规则用「按格统一编码」自证一致（见 RulePlugin 注释）。
	var bq := RuleBuilder.new(rows, cols, _total_mines, next_base)
	if topology != null:
		bq.set_topology(topology)
	if clue_rule != null:
		clue_rule.build_global_clue_constraints(bq)
	aux.append_array(bq.aux_vars)
	next_base = bq.next_aux_index()
	# 各线索 IR（aux 编号顺延，保证 spec 内全局唯一）
	var clues: Array = []
	if clue_rule != null:
		for pos in active:
			if active[pos] == null and not masked.has(pos):
				continue  # 无线索值的安全格：只进 safe_cells，不建约束
			# 【C4 2026-10-01】复用 clue_pkg/interval_pkg 的**缓存 IR**（base=0 构建），
			# 只把 aux 编号平移到本 spec 的区间 —— 取代原先"每条线索、每轮都 new RuleBuilder
			# 重建一遍"（实测占墙钟 5.8%，`_stage0b_out.txt:6`）。语义等价性依据：
			#   ① clue 约束是**局部**的（自身 + 邻域），与 total_mines 无关 —— 这正是 `check()`
			#      一直在用的假设（它早就用 clue_pkg/-1 做黑盒判定）；
			#   ② 平移只改 `{"t":"aux","i":id}` 与 aux 域信息的 `i`，不动约束结构；
			#   ③ 等价性由**黄金网逐字节对拍**守护（任何差异立刻暴露，见 §24.7 验证）。
			if _spec_clue_cache:
				var pkg: Dictionary
				if masked.has(pos):
					var iv: Vector2i = masked[pos]
					pkg = interval_pkg(pos, iv.x, iv.y)
				else:
					pkg = clue_pkg(pos, active[pos])
				var at := _pkg_at(pkg, next_base)
				aux.append_array(at["aux"])
				# 与 b.next_aux_index() 同义：aux id 从 base 起连续分配 ⇒ 前进量 = 本包 aux 个数
				next_base += pkg["aux"].size()
				clues.append({"r": pos.y, "c": pos.x, "ir": at["ir"]})
				continue
			var b := RuleBuilder.new(rows, cols, _total_mines, next_base)
			if topology != null:
				b.set_topology(topology)
			if masked.has(pos):
				var iv2: Vector2i = masked[pos]
				clue_rule.build_interval_constraints(b, pos, iv2.x, iv2.y)
			else:
				clue_rule.build_clue_constraints(b, pos, active[pos])
			aux.append_array(b.aux_vars)
			next_base = b.next_aux_index()
			clues.append({"r": pos.y, "c": pos.x, "ir": b.constraints})
	# 安全格 = 激活线索格；已知雷
	var safe: Array = []
	for pos in active:
		safe.append([pos.y, pos.x])
	# 异形拓扑：包围盒内但不在拓扑的「洞格」约束为非雷（加入 safe_cells，CP-SAT 据此排除洞格）。
	if topology != null:
		for r in rows:
			for c in cols:
				if not topology.in_board(Vector2i(c, r)):
					safe.append([r, c])
	var mine_cells: Array = []
	for m in known_mines:
		mine_cells.append([m.y, m.x])
	# aux 去重（v3.0）：显式索引共享池（bool_var_at/int_var_at）会让「同一索引」在
	# 全局 builder 与逐格 builder 各声明一次——C# 侧声明两次会「覆盖创建」导致引用断裂，
	# 故此处按索引只保留首见条目（首见 = 变量池的创建者）。
	var seen_aux := {}
	var aux_dedup: Array = []
	for av in aux:
		var ai := int(av["i"])
		if not seen_aux.has(ai):
			seen_aux[ai] = true
			aux_dedup.append(av)
	aux = aux_dedup
	var spec := {
		"rows": rows,
		"cols": cols,
		"total_mines": _total_mines,
		"safe_cells": safe,
		"mine_cells": mine_cells,
		"clues": clues,
		"globals": bg.constraints + bq.constraints,
		"aux": aux,
		"timeout_ms": 8000,
	}
	# 【D2】确定性判停：只在下发该键时改变行为（0 = 缺键 = C# 侧原有 2× 墙钟兜底，行为不变）
	if deterministic_steps > 0.0:
		spec["max_deterministic_time"] = deterministic_steps
	if num_workers > 0:
		spec["num_workers"] = num_workers
	# 累计预算（见 var 声明）：只在开启时下发，缺键 = C# 侧默认值（保持旧行为可比）。
	# 调用方可写 spec["probe_budget_ms"] 覆盖（按剩余墙钟收紧）。
	if probe_budget_ms > 0:
		spec["probe_budget_ms"] = probe_budget_ms
	if core_budget_ms > 0:
		spec["core_budget_ms"] = core_budget_ms
	return spec
