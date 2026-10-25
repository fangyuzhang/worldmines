# variant_registry.gd —— 14 个内置变体注册表 + 兼容矩阵（文档附 A/B）
# 变体 = 线索型（clue_variant）+ 可选全局约束（constraint_variant）。
# 每个变体：码、名、线索型、约束型、值域、minimal_clue_value、难度。
class_name VariantRegistry
extends RefCounted

# 变体码
const V_CLASSIC := "classic"
const V_MX := "mx"
const V_RL := "rl"
const V_PF := "pf"
const V_QD := "qd"
const V_DT := "dt"
const V_EP := "ep"
const V_4C := "4c"
const V_4N := "4n"
const V_CLOCK := "clock"
const V_HV := "hv"
const V_FR := "fr"
const V_LOOP_RUNS := "loopruns"
const V_DIST_SUM := "distsum"
const V_SC := "sc"

# 全局约束码列表（7 个）
const GLOBAL_CONSTRAINTS := [V_MX, V_RL, V_PF, V_QD, V_DT, V_EP, V_4C]
# 线索型码列表（7 个，不含经典）
const CLUE_VARIANTS := [V_4N, V_CLOCK, V_HV, V_FR, V_LOOP_RUNS, V_DIST_SUM, V_SC]


## 变体定义表：码 -> { name, clue, constraint, max_value, minimal_clue_value, difficulty }
static func definitions() -> Dictionary:
	return {
		V_CLASSIC: {"name": "经典", "clue": ClueEngine.Variant.CLASSIC, "constraint": -1, "max": 8, "min_clue": 0, "diff": "★★☆☆☆"},
		V_MX: {"name": "镜像", "clue": ClueEngine.Variant.CLASSIC, "constraint": ConstraintEngine.Variant.MX, "max": 8, "min_clue": 0, "diff": "★★★☆☆"},
		V_RL: {"name": "相邻行锁", "clue": ClueEngine.Variant.CLASSIC, "constraint": ConstraintEngine.Variant.RL, "max": 8, "min_clue": 0, "diff": "★★★☆☆"},
		V_PF: {"name": "局部禁形", "clue": ClueEngine.Variant.CLASSIC, "constraint": ConstraintEngine.Variant.PF, "max": 8, "min_clue": 0, "diff": "★★☆☆☆"},
		V_QD: {"name": "四象", "clue": ClueEngine.Variant.CLASSIC, "constraint": ConstraintEngine.Variant.QD, "max": 8, "min_clue": 0, "diff": "★★★☆☆"},
		V_DT: {"name": "骨牌边界", "clue": ClueEngine.Variant.CLASSIC, "constraint": ConstraintEngine.Variant.DT, "max": 8, "min_clue": 0, "diff": "★★★★☆"},
		V_EP: {"name": "端点平衡", "clue": ClueEngine.Variant.CLASSIC, "constraint": ConstraintEngine.Variant.EP, "max": 8, "min_clue": 0, "diff": "★★☆☆☆"},
		V_4C: {"name": "四向守恒", "clue": ClueEngine.Variant.CLASSIC, "constraint": ConstraintEngine.Variant.FOUR_COLOR, "max": 8, "min_clue": 0, "diff": "★★★☆☆"},
		V_4N: {"name": "四邻", "clue": ClueEngine.Variant.N4, "constraint": -1, "max": 4, "min_clue": 0, "diff": "★★☆☆☆"},
		V_CLOCK: {"name": "钟点", "clue": ClueEngine.Variant.CLOCK, "constraint": -1, "max": 8, "min_clue": 0, "diff": "★★★☆☆"},
		V_HV: {"name": "纵横分计", "clue": ClueEngine.Variant.HV, "constraint": -1, "max": 4, "min_clue": 0, "diff": "★★★☆☆"},
		V_FR: {"name": "首雷", "clue": ClueEngine.Variant.FR, "constraint": -1, "max": -1, "min_clue": -1, "diff": "★★★☆☆"},
		V_LOOP_RUNS: {"name": "环游程", "clue": ClueEngine.Variant.LOOP_RUNS, "constraint": -1, "max": 4, "min_clue": 0, "diff": "★★★★☆"},
		V_DIST_SUM: {"name": "曼哈顿和", "clue": ClueEngine.Variant.DIST_SUM, "constraint": -1, "max": 12, "min_clue": 0, "diff": "★★★☆☆"},
		V_SC: {"name": "同色", "clue": ClueEngine.Variant.SAME_COLOR, "constraint": -1, "max": 4, "min_clue": 0, "diff": "★★★☆☆"},
	}


## 全部 14 个内置变体码（含经典）。
static func all_codes() -> Array[String]:
	return [V_CLASSIC, V_MX, V_RL, V_PF, V_QD, V_DT, V_EP, V_4C, V_4N, V_CLOCK, V_HV, V_FR, V_LOOP_RUNS, V_DIST_SUM, V_SC]


## 解析变体码 → { clue, clue2, constraint, constraint2, name, max, min_clue, diff }。未知返回 {}。
## 支持四类：
##   单变体     "mx"（布局+经典）/ "4n"（线索）/ "classic"
##   一布局一线索 "mx+4n" = 镜像约束 + 四邻线索（C 类）
##   双布局     "mx+rl" = 镜像约束 + 相邻行锁约束（F 类，线索为经典）
##   线索混合   "4n+sc" = 同一格同时给出四邻与同色两个线索值（E 类，无全局约束）
static func resolve(code: String) -> Dictionary:
	if definitions().has(code):
		var d: Dictionary = definitions()[code].duplicate()
		d["clue2"] = -1
		d["constraint2"] = -1
		return d
	if code.contains("+"):
		var parts := code.split("+")
		if parts.size() == 2 and definitions().has(parts[0]) and definitions().has(parts[1]):
			var a: Dictionary = definitions()[parts[0]]
			var b: Dictionary = definitions()[parts[1]]
			var a_is_layout: bool = int(a["constraint"]) != -1
			var b_is_layout: bool = int(b["constraint"]) != -1
			# 一布局一线索（A 布局 + B 线索，或 A 线索 + B 布局）
			if a_is_layout and not b_is_layout:
				return {
					"clue": b["clue"], "clue2": -1, "constraint": a["constraint"], "constraint2": -1,
					"name": "%s+%s" % [a["name"], b["name"]],
					"max": b["max"], "min_clue": b["min_clue"], "diff": b["diff"],
				}
			if b_is_layout and not a_is_layout:
				return {
					"clue": a["clue"], "clue2": -1, "constraint": b["constraint"], "constraint2": -1,
					"name": "%s+%s" % [a["name"], b["name"]],
					"max": a["max"], "min_clue": a["min_clue"], "diff": a["diff"],
				}
			# 双布局（两个全局约束，线索为经典）
			if a_is_layout and b_is_layout:
				return {
					"clue": ClueEngine.Variant.CLASSIC, "clue2": -1,
					"constraint": a["constraint"], "constraint2": b["constraint"],
					"name": "%s+%s" % [a["name"], b["name"]],
					"max": 8, "min_clue": 0, "diff": "★★★★☆",
				}
			# 线索混合（两个线索型叠加，一格同时显示两个线索值）
			if not a_is_layout and not b_is_layout:
				return {
					"clue": a["clue"], "clue2": b["clue"], "constraint": -1, "constraint2": -1,
					"name": "%s+%s" % [a["name"], b["name"]],
					"max": maxi(int(a["max"]), int(b["max"])),
					"min_clue": maxi(int(a["min_clue"]), int(b["min_clue"])),
					"diff": "★★★★★",
				}
	return {}


## 取线索型。
static func clue_of(code: String) -> int:
	return definitions()[code]["clue"]


## 取全局约束型（无则 -1）。
static func constraint_of(code: String) -> int:
	return definitions()[code]["constraint"]


## 兼容矩阵（文档附 B.1 全局约束 × 全局约束）。
## 返回 "ok" / "warn" / "forbid"。用于生成器过滤。
static func global_pair_compat(a: String, b: String) -> String:
	var key1 := a + "+" + b
	var key2 := b + "+" + a
	var forbid := ["mx+ep", "ep+mx", "rl+qd", "qd+rl"]
	var warn := ["mx+qd", "qd+mx", "mx+4c", "4c+mx", "qd+ep", "ep+qd", "qd+4c", "4c+qd"]
	if key1 in forbid or key2 in forbid:
		return "forbid"
	if key1 in warn or key2 in warn:
		return "warn"
	return "ok"


## 校验一组全局约束码是否兼容（含互斥）。返回 { ok, reason }。
static func validate_global_combo(codes: Array[String]) -> Dictionary:
	for i in codes.size():
		for j in range(i + 1, codes.size()):
			var r := global_pair_compat(codes[i], codes[j])
			if r == "forbid":
				return {"ok": false, "reason": "%s 与 %s 禁止同关" % [codes[i], codes[j]]}
	# 同关全局约束 ≤ 2（文档 B.1）
	if codes.size() > 2:
		return {"ok": false, "reason": "同关全局约束不得超过 2 个"}
	return {"ok": true, "reason": ""}
