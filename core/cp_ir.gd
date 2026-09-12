# cp_ir.gd —— 可组合约束 IR（自举式规则平台的原语层）
# 设计原则（对齐社区 MinesweeperVariants 的 create_constraints 模式）：
#   1. 有限原语 · 无限组合：与 CP-SAT 自身 API 同构的原语集
#      （cell/aux 变量、const/sum/wsum 表达式、eq/le/lt、bool_or/and/imp/iff、
#       all_diff、enforce 重式化开关），不枚举「线索类型/约束类型」。
#      列多少接口都是有限的——原语的组合是无限的。
#   2. 纯数据：IR 节点全部是 Dictionary/Array，JSON 可序列化 →
#      可进关卡文件（工坊验证无需 mod 代码）、可跨后端（C# OR-Tools 翻译 /
#      GDScript 黑盒求值）、可单测。
#   3. enforce（= CP-SAT OnlyEnforceIf）是重式化开关：
#      删线索、说谎者（恰 k 条线索失效）、动态显隐、可选窗口等高级规则
#      全部由「约束 × 开关字面量」组合表达，无需平台新增接口。
#
# IR 节点格式（跨语言契约，C# 侧见 solver/RuleSolver.cs）：
#   变量引用:  {"t":"cell","r":int,"c":int} | {"t":"aux","i":int}
#   表达式:    {"t":"const","v":int} | {"t":"sum","xs":[expr..]}
#              {"t":"wsum","ws":[int..],"xs":[var|const..]}
#   字面量:    变量引用（布尔语义） | {"t":"not","x":lit}
#   约束:      {"t":"eq"|"le"|"lt","a":expr,"b":expr}
#              {"t":"bool_or"|"bool_and","lits":[lit..]}
#              {"t":"imp"|"iff","a":lit,"b":lit}
#              {"t":"all_diff","xs":[expr..]}
#              {"t":"enforce","lits":[lit..],"c":constraint}
class_name CPIR
extends RefCounted


# ==== 节点类型 ====
const T_CELL := "cell"
const T_AUX := "aux"
const T_CONST := "const"
const T_SUM := "sum"
const T_WSUM := "wsum"
const T_LIN := "lin"
const T_NOT := "not"
const T_EQ := "eq"
const T_LE := "le"
const T_LT := "lt"
const T_BOOL_OR := "bool_or"
const T_BOOL_AND := "bool_and"
const T_IMP := "imp"
const T_IFF := "iff"
const T_ALL_DIFF := "all_diff"
const T_ENFORCE := "enforce"


# ==== 工厂 ====

static func cell_var(r: int, c: int) -> Dictionary:
	return {"t": T_CELL, "r": r, "c": c}


static func aux_var(i: int) -> Dictionary:
	return {"t": T_AUX, "i": i}


static func const_expr(v: int) -> Dictionary:
	return {"t": T_CONST, "v": v}


static func not_lit(lit: Dictionary) -> Dictionary:
	return {"t": T_NOT, "x": lit}


static func sum(xs: Array) -> Dictionary:
	return {"t": T_SUM, "xs": xs.duplicate()}


## 加权和。xs 元素须为变量引用或 const（C# Affine 翻译要求）。
static func wsum(ws: Array, xs: Array) -> Dictionary:
	return {"t": T_WSUM, "ws": ws.duplicate(), "xs": xs.duplicate()}


## 仿射线性表达式：Σ ws[i]·xs[i] + c（xs 元素须为变量引用或 const）。
## 通用原语——sum/wsum 都是它的特例；任意线性约束（差/偏移/组合）都用它表达。
static func lin(ws: Array, xs: Array, c: int = 0) -> Dictionary:
	return {"t": T_LIN, "ws": ws.duplicate(), "xs": xs.duplicate(), "c": c}


static func c_eq(a: Dictionary, b: Dictionary) -> Dictionary:
	return {"t": T_EQ, "a": a, "b": b}


static func c_le(a: Dictionary, b: Dictionary) -> Dictionary:
	return {"t": T_LE, "a": a, "b": b}


static func c_lt(a: Dictionary, b: Dictionary) -> Dictionary:
	return {"t": T_LT, "a": a, "b": b}


static func c_bool_or(lits: Array) -> Dictionary:
	return {"t": T_BOOL_OR, "lits": lits.duplicate()}


static func c_bool_and(lits: Array) -> Dictionary:
	return {"t": T_BOOL_AND, "lits": lits.duplicate()}


static func c_imp(a: Dictionary, b: Dictionary) -> Dictionary:
	return {"t": T_IMP, "a": a, "b": b}


static func c_iff(a: Dictionary, b: Dictionary) -> Dictionary:
	return {"t": T_IFF, "a": a, "b": b}


static func c_all_diff(xs: Array) -> Dictionary:
	return {"t": T_ALL_DIFF, "xs": xs.duplicate()}


## 重式化：仅当全部 lits 为真时 c 才生效（= OnlyEnforceIf）。
static func c_enforce(lits: Array, c: Dictionary) -> Dictionary:
	return {"t": T_ENFORCE, "lits": lits.duplicate(), "c": c}


# ==== 求值（GDScript 黑盒后端：游戏内 oracle / 回退 / 交叉验证） ====

## 赋值键：cell → "r,c"（0/1，缺省 0 = 安全）；aux → "a<i>"。
static func cell_key(r: int, c: int) -> String:
	return "%d,%d" % [r, c]


static func aux_key(i: int) -> String:
	return "a%d" % i


static func eval_expr(e: Dictionary, asg: Dictionary) -> int:
	match e.get("t", ""):
		T_CONST:
			return int(e["v"])
		T_CELL:
			return int(asg.get(cell_key(e["r"], e["c"]), 0))
		T_AUX:
			return int(asg.get(aux_key(e["i"]), 0))
		T_SUM:
			var s := 0
			for x in e["xs"]:
				s += eval_expr(x, asg)
			return s
		T_WSUM:
			var xs: Array = e["xs"]
			var ws: Array = e["ws"]
			var s := 0
			for i in xs.size():
				s += int(ws[i]) * eval_expr(xs[i], asg)
			return s
		T_LIN:
			var xs2: Array = e["xs"]
			var ws2: Array = e["ws"]
			var s2 := int(e.get("c", 0))
			for i in xs2.size():
				s2 += int(ws2[i]) * eval_expr(xs2[i], asg)
			return s2
	push_error("CPIR: 未知表达式节点 %s" % str(e.get("t", "")))
	return 0


static func eval_lit(lit: Dictionary, asg: Dictionary) -> bool:
	match lit.get("t", ""):
		T_NOT:
			return not eval_lit(lit["x"], asg)
		T_CELL, T_AUX, T_CONST:
			# T_CONST：const 0 = false / 非 0 = true。支持它使「越界 cell_var（const 0）
			# 直接入或门」可用——RuleBuilder.cell_var 注释承诺的越界语义
			#（「方便写射线/环序等开窗口规则」）此前在字面量位置不成立（mod 试验抓出）。
			return eval_expr(lit, asg) != 0
	push_error("CPIR: 未知字面量节点 %s" % str(lit.get("t", "")))
	return false


static func eval_constraint(c: Dictionary, asg: Dictionary) -> bool:
	match c.get("t", ""):
		T_EQ:
			return eval_expr(c["a"], asg) == eval_expr(c["b"], asg)
		T_LE:
			return eval_expr(c["a"], asg) <= eval_expr(c["b"], asg)
		T_LT:
			return eval_expr(c["a"], asg) < eval_expr(c["b"], asg)
		T_BOOL_OR:
			for l in c["lits"]:
				if eval_lit(l, asg):
					return true
			return false
		T_BOOL_AND:
			for l in c["lits"]:
				if not eval_lit(l, asg):
					return false
			return true
		T_IMP:
			return (not eval_lit(c["a"], asg)) or eval_lit(c["b"], asg)
		T_IFF:
			return eval_lit(c["a"], asg) == eval_lit(c["b"], asg)
		T_ALL_DIFF:
			var vals: Array[int] = []
			for x in c["xs"]:
				var v := eval_expr(x, asg)
				if vals.has(v):
					return false
				vals.append(v)
			return true
		T_ENFORCE:
			for l in c["lits"]:
				if not eval_lit(l, asg):
					return true  # 开关未全开 → 约束不生效
			return eval_constraint(c["c"], asg)
	push_error("CPIR: 未知约束节点 %s" % str(c.get("t", "")))
	return false


static func eval_all(constraints: Array, asg: Dictionary) -> bool:
	for c in constraints:
		if not eval_constraint(c, asg):
			return false
	return true


## aux 存在性求值：∃aux 赋值使全部约束为真（回溯，防爆炸有上限）。
## aux_vars 为完整域信息：[{"i":int,"kind":"bool"} | {"i":int,"kind":"int","lo":int,"hi":int}]。
## 布尔 aux 回溯 0/1；整数 aux 回溯 [lo, hi]（P3：补齐 int_var 黑盒求值，消除"C# only"缺口）。
## 求值过程可能向 asg 写入 aux 值（成功时保留，失败时清理）。
static func eval_with_aux(constraints: Array, asg: Dictionary, aux_vars: Array, cap := 100000) -> bool:
	if aux_vars.is_empty():
		return eval_all(constraints, asg)
	var vars: Array = _normalize_aux(aux_vars)
	# 熔断：总组合数 = 布尔 aux(2) × int aux 域大小的乘积，防整数域爆炸
	var total := 1
	for a in vars:
		if str(a.get("kind", "bool")) == "int":
			total *= (int(a["hi"]) - int(a["lo"]) + 1)
		else:
			total *= 2
		if total > cap:
			push_warning("CPIR: aux 组合数 %d 超过回溯上限 %d，判为不满足（请走 C# 后端）" % [total, cap])
			return false
	return _aux_backtrack(constraints, asg, vars, 0)


## 归一化 aux 参数：兼容旧格式（Array[int]，视为布尔 aux）与新格式（Array[Dictionary]）。
static func _normalize_aux(aux_vars: Array) -> Array:
	var out: Array = []
	for a in aux_vars:
		if a is Dictionary:
			out.append(a)
		else:
			out.append({"i": int(a), "kind": "bool"})
	return out


static func _aux_backtrack(constraints: Array, asg: Dictionary, vars: Array, idx: int) -> bool:
	if idx == vars.size():
		return eval_all(constraints, asg)
	var a: Dictionary = vars[idx]
	var key := aux_key(int(a["i"]))
	if str(a.get("kind", "bool")) == "int":
		for v in range(int(a["lo"]), int(a["hi"]) + 1):
			asg[key] = v
			if _aux_backtrack(constraints, asg, vars, idx + 1):
				return true
		asg.erase(key)
	else:
		asg[key] = 0
		if _aux_backtrack(constraints, asg, vars, idx + 1):
			return true
		asg[key] = 1
		if _aux_backtrack(constraints, asg, vars, idx + 1):
			return true
		asg.erase(key)
	return false
