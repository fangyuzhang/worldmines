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

## C# CP-SAT 并行搜索 worker 数（0 = 用 C# 默认 4）。由 PuzzleGenerator.num_workers 透传；
## 分片批跑时设为 1，避免多进程各自开 4 worker 超额订阅。不影响强制格结论。
var num_workers: int = 0


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
	# 各线索 IR（aux 编号顺延，保证 spec 内全局唯一）
	var clues: Array = []
	if clue_rule != null:
		for pos in active:
			if active[pos] == null and not masked.has(pos):
				continue  # 无线索值的安全格：只进 safe_cells，不建约束
			var b := RuleBuilder.new(rows, cols, _total_mines, next_base)
			if topology != null:
				b.set_topology(topology)
			if masked.has(pos):
				var iv: Vector2i = masked[pos]
				clue_rule.build_interval_constraints(b, pos, iv.x, iv.y)
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
	var spec := {
		"rows": rows,
		"cols": cols,
		"total_mines": _total_mines,
		"safe_cells": safe,
		"mine_cells": mine_cells,
		"clues": clues,
		"globals": bg.constraints,
		"aux": aux,
		"timeout_ms": 8000,
	}
	if num_workers > 0:
		spec["num_workers"] = num_workers
	return spec
