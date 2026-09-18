# core/rule_signature.gd -- 算子代数签名与组合性判据（替换手写 forbid/warn 表）
# 
# 背景：core/variant_registry.gd:121 的 global_pair_compat 是手写互斥表，
#   只能表达"这两个不能同关"，无法解释**为什么**，也无法在新增算子时复用。
#
# 本模块把组合性变成**可推导的性质**：
#   每个算子声明一个代数签名 sigma = (obj, scope, sym, div, implies)
#   compat() 按 R1~R5 五条判据推导 verdict = ok / warn / forbid
#
# 纯增量模块：不修改任何现有代码。接入方式见文件末尾 "接入步骤"。
#
# 坐标约定沿用项目：Vector2i(col, row)，即 x=列、y=行。

class_name RuleSignature
extends RefCounted


# === 作用对象（决定跨轴正交性）===
enum Obj {
	OBS,    # 观测：作用在 f(B)，改"看到什么"
	LOCAL,  # 局部模式：作用在有限窗口
	TOPO,   # 拓扑：作用在连通分量
	COUNT,  # 计数投影：作用在低维投影（行/列/区域/染色和）
}

# === 作用域 ===
enum Scope {
	POINT,    # 逐点
	WINDOW,   # k x k 窗口（k 见 win 字段）
	ROW,      # 行 profile
	COL,      # 列 profile
	REGION,   # 区域分块
	ADJ,      # 连通分量
	GLOBAL,   # 全盘单一标量
}

# === 对称群位掩码：算子**保持**的对称 ===
const SYM_NONE := 0
const SYM_MIR_H := 1    # 左右镜像 c -> C-1-c
const SYM_MIR_V := 2    # 上下镜像 r -> R-1-r
const SYM_ROT90 := 4    # 90 度旋转
const SYM_MIR_D := 8    # 主对角镜像
const SYM_D4 := 15      # 全部（各向同性）

# === 整除约束种类：div 条目 = [kind, arg] ===
enum Div {
	NONE,            # 无约束
	MOD_EQ,          # N % arg == 0
	MOD_EQ_MINUS_C,  # (N - center) % arg == 0，center = 中央行列的格数
	EVEN,            # N % 2 == 0
	EXACT_HALF,      # N == floor(R*C/2)（完全覆盖的 2x1 骨牌数）
}

# === 判决 ===
const OK := "ok"
const WARN := "warn"
const FORBID := "forbid"


## 签名表。obj/scope/sym/div/implies 五元组。
## implies：本算子**逻辑蕴含**的其它算子 id（两者同时出现在同一关时，后者完全冗余 -> R4 forbid）。
## win：scope == WINDOW 时的窗口边长。
static func table() -> Dictionary:
	# 基础表：内置换算子 + 轴 S 的设计期泛化名（`iso` / `notri` / `dense`… 保留，历史引用可能还在）
	var t := {
		# ---------- 轴 O：观测通道（作用在 f）----------
		"classic":   {"obj": Obj.OBS, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []},
		"4n":        {"obj": Obj.OBS, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []},
		"sc":        {"obj": Obj.OBS, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []},
		"distsum":   {"obj": Obj.OBS, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []},
		"hv":        {"obj": Obj.OBS, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []},
		"loopruns":  {"obj": Obj.OBS, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []},
		"knight":    {"obj": Obj.OBS, "scope": Scope.POINT, "win": 5, "sym": SYM_D4, "div": [], "implies": []},
		# 各向异性观测：只有恒等对称 -> 与任何 SYM_MIR_H 布局算子都可疑 R3
		"clock":     {"obj": Obj.OBS, "scope": Scope.POINT, "win": 3, "sym": SYM_NONE, "div": [], "implies": []},
		"fr":        {"obj": Obj.OBS, "scope": Scope.ROW, "win": 1, "sym": SYM_NONE, "div": [], "implies": []},

		# ---------- 轴 S：局部结构 / 拓扑 ----------
		"iso":       {"obj": Obj.LOCAL, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []},
		"pair":      {"obj": Obj.LOCAL, "scope": Scope.POINT, "win": 3, "sym": SYM_MIR_H | SYM_MIR_V, "div": [], "implies": []},
		"notri":     {"obj": Obj.LOCAL, "scope": Scope.WINDOW, "win": 3, "sym": SYM_D4, "div": [], "implies": []},
		"dense":     {"obj": Obj.LOCAL, "scope": Scope.WINDOW, "win": 2, "sym": SYM_D4, "div": [], "implies": []},
		"seg":       {"obj": Obj.LOCAL, "scope": Scope.ROW, "win": 1, "sym": SYM_MIR_H, "div": [], "implies": []},
		"conn":      {"obj": Obj.TOPO, "scope": Scope.ADJ, "win": 0, "sym": SYM_D4, "div": [], "implies": []},
		"grpk":      {"obj": Obj.TOPO, "scope": Scope.ADJ, "win": 0, "sym": SYM_D4, "div": [[Div.MOD_EQ, 4]], "implies": []},

		# ---------- 轴 Z：全局守恒（低维投影）----------
		"mx":        {"obj": Obj.COUNT, "scope": Scope.POINT, "win": 1, "sym": SYM_MIR_H,
			"div": [], "implies": ["ep"]},
		"rl":        {"obj": Obj.COUNT, "scope": Scope.ROW, "win": 1, "sym": SYM_NONE, "div": [], "implies": []},
		"qd":        {"obj": Obj.COUNT, "scope": Scope.REGION, "win": 0, "sym": SYM_ROT90,
			"div": [[Div.MOD_EQ_MINUS_C, 4]], "implies": []},
		"4c":        {"obj": Obj.COUNT, "scope": Scope.GLOBAL, "win": 0, "sym": SYM_ROT90,
			"div": [[Div.EVEN, 2]], "implies": []},
		"ep":        {"obj": Obj.COUNT, "scope": Scope.COL, "win": 1, "sym": SYM_MIR_H, "div": [], "implies": []},
		"dt":        {"obj": Obj.COUNT, "scope": Scope.REGION, "win": 0, "sym": SYM_NONE,
			"div": [[Div.EXACT_HALF, 2]], "implies": []},
	}
	return _with_official(t)


## 官方 22 席（GDD §4）的签名 —— 为什么必须入表：
## `compat()` 对未登记的 id 一律回退 `warn`（R0）。于是官方组合在混合档里只能显示泛化文案，
## 更糟的是 **R4 蕴含 / R5 整除** 这两类真正该被禁止的组合推导不出来（会留下死格）。
##
## 与旧席位**同规则**的 5 席（`o8`=钟点 / `o10`=环游 / `z1`=镜像 / `z2`=相邻行锁 / `z3`=四象）
## 直接**引用**旧签名而不是复制一份：它们是同一条规则的两份实现，代数身份必须永远一致
## —— 引用能保证「改一处两处同步」，复制迟早漂移。
## 其余 17 席按 GDD §4.2（观测）/ §4.4（结构）/ §4.5（守恒）的数学定义填写。
static func _with_official(t: Dictionary) -> Dictionary:
	# ---- 观测轴 O1~O10（win = 线索窗口边长；对穿/斜脉/射距跨行跨列，故 win 记 0）----
	t["o1"]  = {"obj": Obj.OBS, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []}   # 四条轴两端成雷：轴集合在 D4 下封闭
	t["o2"]  = {"obj": Obj.OBS, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []}   # 八邻域内比大小
	t["o3"]  = {"obj": Obj.OBS, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []}   # 八邻计数单调压缩
	t["o4"]  = {"obj": Obj.OBS, "scope": Scope.POINT, "win": 5, "sym": SYM_D4, "div": [], "implies": []}   # 半径 2 = 5×5；隐藏半径不改对称性
	t["o5x"] = {"obj": Obj.OBS, "scope": Scope.POINT, "win": 0, "sym": SYM_D4, "div": [], "implies": []}   # 两条对角线过本格，在 D4 下互换
	t["o6"]  = {"obj": Obj.OBS, "scope": Scope.POINT, "win": 5, "sym": SYM_D4, "div": [], "implies": []}   # 二阶邻域 = 5×5
	t["o7"]  = {"obj": Obj.OBS, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []}   # 奇偶剥夺不改对称
	t["o8"]  = t["clock"]
	t["o9"]  = {"obj": Obj.OBS, "scope": Scope.ROW, "win": 1, "sym": SYM_D4, "div": [], "implies": []}     # 四向射线取最小（fr 是单向，故其 sym 为 NONE）
	t["o10"] = t["loopruns"]

	# ---- 结构轴 S1~S7 ----
	t["s1"] = {"obj": Obj.LOCAL, "scope": Scope.WINDOW, "win": 2, "sym": SYM_D4, "div": [], "implies": []}   # 2×2 窗口 ≤2 雷
	t["s2"] = {"obj": Obj.COUNT, "scope": Scope.GLOBAL, "win": 0, "sym": SYM_D4, "div": [], "implies": []}   # 一阶矩落在中心 ± 半格
	t["s3"] = {"obj": Obj.TOPO, "scope": Scope.ADJ, "win": 0, "sym": SYM_D4, "div": [], "implies": []}       # 森林（无环）
	t["s4"] = {"obj": Obj.COUNT, "scope": Scope.GLOBAL, "win": 0, "sym": SYM_D4, "div": [], "implies": []}   # 分层密度单调（层 = 到边界距离）
	t["s5"] = {"obj": Obj.LOCAL, "scope": Scope.ROW, "win": 1, "sym": SYM_MIR_H, "div": [], "implies": []}   # 每行/列内连续
	t["s6"] = {"obj": Obj.LOCAL, "scope": Scope.POINT, "win": 3, "sym": SYM_D4, "div": [], "implies": []}     # 每颗雷的八邻雷数为偶
	t["s7"] = {"obj": Obj.TOPO, "scope": Scope.ADJ, "win": 0, "sym": SYM_D4, "div": [], "implies": []}       # 分量数恰 K（与 s3 同 scope → R2 warn，正是 GDD §5.3 的 J2）

	# ---- 守恒轴 Z1~Z5 ----
	t["z1"] = t["mx"]
	t["z2"] = t["rl"]
	t["z3"] = t["qd"]
	t["z4"] = {"obj": Obj.COUNT, "scope": Scope.ROW, "win": 1, "sym": SYM_MIR_D, "div": [], "implies": []}   # 行 profile = 列 profile（转置不变）
	t["z5"] = {"obj": Obj.COUNT, "scope": Scope.ROW, "win": 1,
		"sym": SYM_MIR_H | SYM_MIR_V, "div": [], "implies": []}                                             # 各行雷数成等差
	return t


## 兼容判决。size = Vector2i(cols, rows)，mines = 总雷数 N。
## 返回 {verdict: String, reason: String, rules: Array[String]}。
static func compat(a: String, b: String, size: Vector2i, mines: int) -> Dictionary:
	var t := table()
	if not t.has(a) or not t.has(b):
		return {"verdict": WARN, "reason": "未知算子签名，回退为 warn", "rules": ["R0"]}
	if a == b:
		return {"verdict": FORBID, "reason": "同一算子不可重复", "rules": ["R0"]}
	var sa: Dictionary = t[a]
	var sb: Dictionary = t[b]
	var why: Array[String] = []

	# R4 蕴含：一方逻辑蕴含另一方 -> 后者完全冗余
	if (sa["implies"] as Array).has(b):
		return {"verdict": FORBID, "reason": "%s 逻辑蕴含 %s，后者完全冗余" % [a, b], "rules": ["R4"]}
	if (sb["implies"] as Array).has(a):
		return {"verdict": FORBID, "reason": "%s 逻辑蕴含 %s，后者完全冗余" % [b, a], "rules": ["R4"]}

	# R5 整除约束：合并后需有解
	var merged: Array = (sa["div"] as Array) + (sb["div"] as Array)
	for d in merged:
		var kind: int = (d as Array)[0]
		var arg: int = (d as Array)[1]
		if not _div_ok(kind, arg, size, mines):
			why.append("R5")
			return {"verdict": FORBID, "reason": "总雷数 %d 不满足整除约束 kind=%d mod=%d" % [mines, kind, arg],
				"rules": ["R5"]}

	# R1 跨轴正交：作用对象不同 -> 恒可组合
	if sa["obj"] != sb["obj"]:
		why.append("R1")
		return {"verdict": OK, "reason": "作用对象不同（%s vs %s），天然正交" % [_obj_name(sa["obj"]), _obj_name(sb["obj"])],
			"rules": why}

	# R3 对称群相容：两算子保持的对称群必须相交
	var inter: int = (sa["sym"] as int) & (sb["sym"] as int)
	if inter == SYM_NONE:
		why.append("R3")
		return {"verdict": WARN, "reason": "对称群无交集，可行域可能急剧塌缩", "rules": why}

	# R2 同轴：作用域相同或嵌套 -> 可能互相锁定，交由生成器时取样接受率低下
	if sa["scope"] == sb["scope"]:
		why.append("R2")
		return {"verdict": WARN, "reason": "同一作用域叠加（%s），需 CP-SAT 可行性复核" % _scope_name(sa["scope"]),
			"rules": why}

	why.append("R1")
	return {"verdict": OK, "reason": "同轴但作用域与对称群相容", "rules": why}


## 一组算子是否整体兼容（两两判定 + 合并整除约束）。
static func compat_all(ids: Array[String], size: Vector2i, mines: int) -> Dictionary:
	var worst := OK
	var notes: Array[String] = []
	# 合并全部整除约束后再验一次（两两通过不代表三个一起通过）
	var merged: Array = []
	for i in ids.size():
		if not table().has(ids[i]):
			continue
		merged.append_array((table()[ids[i]]["div"] as Array))
	for d in merged:
		var kind: int = (d as Array)[0]
		var arg: int = (d as Array)[1]
		if not _div_ok(kind, arg, size, mines):
			return {"verdict": FORBID,
				"reason": "合并整除约束无解（N=%d）" % mines, "rules": ["R5"]}
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var r := compat(ids[i], ids[j], size, mines)
			notes.append("%s+%s -> %s" % [ids[i], ids[j], r["verdict"]])
			if r["verdict"] == FORBID:
				return {"verdict": FORBID, "reason": r["reason"], "rules": [r["reason"]], "notes": notes}
			if r["verdict"] == WARN:
				worst = WARN
	return {"verdict": worst, "reason": "", "rules": [], "notes": notes}


## 整除约束求值。
static func _div_ok(kind: int, arg: int, size: Vector2i, mines: int) -> bool:
	var cells: int = size.x * size.y
	match kind:
		Div.NONE:
			return true
		Div.MOD_EQ:
			return mines % arg == 0
		Div.EVEN:
			return mines % 2 == 0
		Div.MOD_EQ_MINUS_C:
			# 中央行列：奇数维存在中轴，需先从 N 中扣除中轴上的雷（保守取格数上界）
			var center := 0
			if size.y % 2 == 1:
				center += size.x
			if size.x % 2 == 1:
				center += size.y
			if size.x % 2 == 1 and size.y % 2 == 1:
				center -= 1
			# 中轴上的雷数在 [0, center] 间可变，故要求 (N - t) % 4 == 0 对某一 t 可达
			for t in center + 1:
				if (mines - t) % arg == 0:
					return true
			return false
		Div.EXACT_HALF:
			# 完全覆盖时骨牌数 = floor(R*C/2)，每骨牌恰 1 雷 -> N 必须精确等于它
			var dominoes: int = cells / arg
			if mines == dominoes:
				return true
			# 部分覆盖：划分 k 个骨牌后，剩余自由格补足 -> 只需 k <= N <= k + (cells - 2k)
			var max_k: int = mini(cells / arg, mines)
			return max_k >= 0 and mines <= cells - max_k
		_:
			return true


static func _obj_name(o: int) -> String:
	match o:
		Obj.OBS: return "观测"
		Obj.LOCAL: return "局部结构"
		Obj.TOPO: return "拓扑"
		Obj.COUNT: return "计数投影"
		_: return "?"


static func _scope_name(s: int) -> String:
	match s:
		Scope.POINT: return "逐点"
		Scope.WINDOW: return "窗口"
		Scope.ROW: return "行"
		Scope.COL: return "列"
		Scope.REGION: return "区域"
		Scope.ADJ: return "连通分量"
		Scope.GLOBAL: return "全盘"
		_: return "?"


# ============================================================================
# 附：数学依据备忘（为什么表这么填）
#
# mx implies ep
#   _check_mx 遍历 x < mirror_x 要求 B(c, r) == B(C-1-c, r)。取 c = 0 即
#   B(0, r) == B(C-1, r) 对所有 r 成立 -> C(0) == C(C-1)，正是 ep 的定义。严格蕴含。
#
# mx implies 4c（当列数 C 为偶数）
#   C 偶数 -> C-1 为奇数 -> c 与 C-1-c 奇偶相反 -> 每个被镜像配对的雷必成对出现在异色格
#   -> black == white，正是 4c 的定义。故偶数列盘面下 mx+4c 冗余。
#   （奇数列时中轴列自映射，不保证，故签名表未把它写死，交由生成器取样发现。）
#
# qd 的整除要求 (N - center) % 4 == 0
#   四象限均分要求每个象限雷数相等，中轴上的雷不计入任何象限 ->
#   需 (N - 中轴雷数) 被 4 整除。6x6/N=14 时 (14 - 0) % 4 = 2 -> 数学 UNSAT，
#   与既有 43 个 UNSAT 单元的实测吻合。
#
# dt 的 N == floor(RC/2)
#   完全覆盖时每骨牌恰 1 雷 -> N 恰等于骨牌数 = floor(RC/2)；
#   5x5 需 N = 12.5，不可能 -> 这是 dt 与 R07 固定雷数契约冲突的根源。
# ============================================================================
