# variant_constraint.gd —— 通用变体约束检查器（文档 §5.2 独立性铁律）
# 注入 BruteForceOracle 的 constraint_check 回调，支持任意线索型 + 全局约束。
# 规则自然语言定义：
#   线索格显示的值 = 该变体线索函数在其邻域/窗口上计算的结果；
#   全局约束型额外要求整盘雷分布满足对称/计数/配对等关系。
class_name VariantConstraint
extends RefCounted

# 线索型（ClueEngine.Variant）
var clue: int = ClueEngine.Variant.CLASSIC
var clue2: int = -1       # 第二线索型（-1 = 无，E 类线索混合）
# 全局约束（ConstraintEngine.Variant，-1 = 无）
var constraint: int = -1
var constraint2: int = -1  # 双布局第二全局约束（-1 = 无）
var dominoes: Array = []  # DT 骨牌数据


func _init(p_clue: int = ClueEngine.Variant.CLASSIC, p_constraint: int = -1, p_dominoes: Array = [], p_constraint2: int = -1, p_clue2: int = -1) -> void:
	clue = p_clue
	clue2 = p_clue2
	constraint = p_constraint
	constraint2 = p_constraint2
	dominoes = p_dominoes


## 判断候选雷分布 mine_set 是否满足全部已翻开格约束 + 全局约束。
## 签名与 BruteForceOracle.query 的 check 参数一致。
func check(mine_set: Array[Vector2i], revealed: Dictionary, grid_size: Vector2i) -> bool:
	var ms := {}
	for p in mine_set:
		ms[p] = true

	for pos in revealed:
		var c: Dictionary = revealed[pos]
		if c.get("type", "") == "equality_multi":
			# E 类线索混合：items 按序对应 clue / clue2，逐个用各自线索型校验
			var items: Array = c["items"]
			var clues: Array[int] = [clue, clue2]
			for i in items.size():
				if not _check_one(clues[i], items[i], ms, pos, grid_size):
					return false
			continue
		if not _check_one(clue, c, ms, pos, grid_size):
			return false

	# 全局约束
	if constraint >= 0:
		if not ConstraintEngine.check(constraint, ms, grid_size, {"dominoes": dominoes}):
			return false
	# 双布局第二全局约束
	if constraint2 >= 0:
		if not ConstraintEngine.check(constraint2, ms, grid_size, {"dominoes": dominoes}):
			return false
	return true


## 校验单个线索约束（指定线索型 + 约束 dict）。
func _check_one(cv: int, c: Dictionary, ms: Dictionary, pos: Vector2i, grid_size: Vector2i) -> bool:
	var val: Variant = ClueEngine.compute(cv, ms, pos, grid_size)
	match c.get("type", ""):
		"equality":
			# FR 值域含哨兵 "inf"（String）与整数混合 ⇒ 用字符串化比较，避免 int/String 直接 != 报错。
			if str(val) != str(c["value"]):
				return false
		"equality_pair":
			if not (val is Array) or val[0] != c["a"] or val[1] != c["b"]:
				return false
		"interval":
			if not (val is int):
				return false
			if val < c["lo"] or val > c["hi"]:
				return false
	return true
