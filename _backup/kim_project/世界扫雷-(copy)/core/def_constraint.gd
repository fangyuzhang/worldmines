# def_constraint.gd —— Def 驱动约束检查器（文档 §2.6）
# 与 VariantConstraint 同签名（check(mine_set, revealed, grid_size)），但用 DefEngine，
# 支持 mod 自定义线索/约束 Def 参与 Oracle 的唯一解校验与生成。
class_name DefConstraint
extends RefCounted

var clue_def_name: String = ""
var constraint_def_name: String = ""
var engine: DefEngine
var dominoes: Array = []  # DT 骨牌数据


func _init(p_engine: DefEngine = null, p_clue_def_name: String = "", p_constraint_def_name: String = "", p_dominoes: Array = []) -> void:
	engine = p_engine if p_engine != null else DefEngine.new()
	clue_def_name = p_clue_def_name
	constraint_def_name = p_constraint_def_name
	dominoes = p_dominoes


## 判断候选雷分布 mine_set 是否满足全部已翻开格约束 + 全局约束。
## 签名与 BruteForceOracle 的 check 参数一致。
func check(mine_set: Array[Vector2i], revealed: Dictionary, grid_size: Vector2i) -> bool:
	var ms := {}
	for p in mine_set:
		ms[p] = true

	for pos in revealed:
		var c: Dictionary = revealed[pos]
		var val: Variant = engine.compute_clue(clue_def_name, ms, pos, grid_size)
		match c.get("type", ""):
			"equality":
				if val != c["value"]:
					return false
			"equality_pair":
				if not (val is Array) or val[0] != c["a"] or val[1] != c["b"]:
					return false
			"interval":
				if not (val is int):
					return false
				if val < c["lo"] or val > c["hi"]:
					return false

	if constraint_def_name != "":
		if not engine.check_constraint(constraint_def_name, ms, grid_size, {"dominoes": dominoes}):
			return false
	return true
