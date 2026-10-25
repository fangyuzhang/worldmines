# rule_cpsat.gd —— CP-SAT 计数代理（C# 快速路径 + GDScript 回退枚举）
# 双后端（交叉验证设计：两套独立实现，结果必须一致，测试持续对拍）：
#   - C# RuleSolver（OR-Tools CP-SAT 约束传播）：生产路径
#   - GDScript fallback_count（自由格组合枚举 + IR 黑盒求值）：无 C# 环境 /
#     小盘 / 测试对拍
class_name RuleCpSat
extends RefCounted

## GDScript 回退枚举的总雷数必须已知（spec.total_mines >= 0）。
static var _solver: Object = null
static var _probed := false
## 【2026-10-25 线程化】C# 单例实例的互斥锁：no_guess_guard 的投机预计算会在后台线程
## 调 find_forced_cells，与主线程（生成/提示/同步兜底）并发使用同一实例会互相踩踏
## 内部解析状态（实测报 "Cannot evaluate '' in an integer expression" 后返回 Nil）。
## 所有 _solver 调用必须持锁；锁内只有 C# 调用本身，无回调回 GDScript，无死锁面。
static var _mutex := Mutex.new()


## C# 后端是否可用（探测一次并缓存实例）。
static func available() -> bool:
	if not _probed:
		_probed = true
		var script: Variant = load("res://solver/RuleSolver.cs")
		if script != null:
			var inst: Variant = script.new()
			if inst != null and inst.has_method("CountSolutions"):
				_solver = inst
	return _solver != null


## 唯一解计数：0=无解 1=唯一 2=多解（截断）。spec 见 RuleOracle.build_spec。
static func count_solutions(spec: Dictionary) -> int:
	if available():
		_mutex.lock()
		var r := int(_solver.CountSolutions(spec))
		_mutex.unlock()
		return r
	return fallback_count(spec)


## 序贯演绎（forced-cell 检测）：返回被强制的格 {"safe":[[r,c]..], "mine":[[r,c]..]}。
## 两者皆空 = 无强制格（需猜测）。替代全盘枚举，是生成加速的核心。
## C# 不可用时返回空（保守降级：判为需猜测，生成失败但不产出坏关卡）。
static func find_forced_cells(spec: Dictionary) -> Dictionary:
	if available():
		_mutex.lock()
		var r: Dictionary = _solver.FindForcedCells(spec)
		_mutex.unlock()
		return r
	return {}


## 快速可行性判断：是否存在至少一个满足全部约束 + 总雷数的解（不判唯一）。
## 生成前预筛用——UNSAT（规则冗余/矛盾、雷数不可达）直接返回 false，
## 避免对不可能的组合进入「换 seed 重试」的暴力生成（那会白跑几十秒）。
static func is_feasible(spec: Dictionary) -> bool:
	if available():
		_mutex.lock()
		var r := bool(_solver.IsFeasible(spec))
		_mutex.unlock()
		return r
	# 无 C# 后端：枚举到第一个解即真（max_count=1，找到即停；小盘可用）
	return fallback_count(spec, 1) >= 1


## 采样一个满足全部约束 + 总雷数的雷布局（第一可行解）。
## 多 G 组合的构造式布雷用——替代「只取第一个 G 的 place_mines」的旧策略
##（见 puzzle_generator._place_mines_rules），避免状态性 G（dt）丢失 / 接受率极低。
## 返回 Array[Vector2i]（内部坐标 (c,r)）；无解 / C# 不可用时返回空数组。
static func find_solution(spec: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not available():
		return out
	var raw: Array = _solver.FindSolution(spec)
	for cell in raw:
		var a: Array = cell
		if a.size() >= 2:
			out.append(Vector2i(int(a[1]), int(a[0])))  # C# 返回 [r,c] → 内部 Vector2i(c,r)
	return out


## 单格强制探测（P0-难度量化）：判断 (r,c) 是否被当前约束集「强制」。
## 比 find_forced_cells 便宜（只做 2 次 assumption 探测，不遍历全部自由格），
## 用于「必要线索数」贪心移除——每移除一条线索就测一次 target 是否仍被强制。
## C# 不可用时保守返回 false（判为未被强制）。
static func is_forced_cell(spec: Dictionary, r: int, c: int) -> bool:
	if available():
		return bool(_solver.IsForcedCell(spec, r, c))
	return false


## 必要线索数（unsat_core 方案）：返回使格 (r,c) 被强制（必雷/必安全）所需的最少线索数。
## 对齐对标游戏的「最少线索数」复杂度（精确版近似 MUS）：
## 每条线索用 use_i 门控，assumptions 全激活，假设格取某值不可满足 → unsat_core = 必要线索子集。
## 返回 -1 表示格不被强制（两方向都可满足）。无 C# 后端时返回 -1。
static func minimal_clue_count_unsat(spec: Dictionary, r: int, c: int) -> int:
	if available():
		return int(_solver.MinimalForcedClueCount(spec, r, c))
	return -1


# ==== GDScript 回退枚举（独立实现，用于对拍与无 C# 环境） ====

static func fallback_count(spec: Dictionary, max_count: int = 2) -> int:
	var rows := int(spec["rows"])
	var cols := int(spec["cols"])
	var total := int(spec["total_mines"])
	if total < 0:
		push_warning("RuleCpSat.fallback_count: 缺少 total_mines，无法枚举")
		return 0
	var safe := {}
	var mines := {}
	for s in spec["safe_cells"]:
		safe[Vector2i(int(s[1]), int(s[0]))] = true
	for m in spec["mine_cells"]:
		mines[Vector2i(int(m[1]), int(m[0]))] = true
	var free: Array[Vector2i] = []
	for r in rows:
		for c in cols:
			var p := Vector2i(c, r)
			if not safe.has(p) and not mines.has(p):
				free.append(p)
	# 全部约束合并（spec 内 aux 编号已全局唯一 → 单次回溯求值）
	var constraints: Array = []
	for cl in spec["clues"]:
		for node in cl["ir"]:
			constraints.append(node)
	for node in spec["globals"]:
		constraints.append(node)
	var aux_vars: Array = spec["aux"].duplicate(true)  # 完整域信息（P3：支持 int aux 整数域）
	var asg := {}
	for m in mines:
		asg[CPIR.cell_key(m.y, m.x)] = 1
	var box := [0]
	_dfs_count(free, 0, total - mines.size(), asg, constraints, aux_vars, box, max_count)
	return box[0]


static func _dfs_count(free: Array[Vector2i], idx: int, need: int, asg: Dictionary,
		constraints: Array, aux_vars: Array, box: Array, max_count: int) -> void:
	if box[0] >= max_count or need < 0:
		return
	if need > free.size() - idx:
		return
	if idx == free.size():
		if need == 0 and CPIR.eval_with_aux(constraints, asg, aux_vars):
			box[0] += 1
		return
	var p := free[idx]
	var key := CPIR.cell_key(p.y, p.x)
	asg[key] = 1
	_dfs_count(free, idx + 1, need - 1, asg, constraints, aux_vars, box, max_count)
	asg.erase(key)
	_dfs_count(free, idx + 1, need, asg, constraints, aux_vars, box, max_count)
