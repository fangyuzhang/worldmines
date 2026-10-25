# classic_constraint.gd —— 经典规则约束检查器（文档 §5.2 独立性铁律）
# 这是注入 BruteForceOracle 的 constraint_check 回调。
# 规则自然语言定义：数字格的值 = 其 8 邻域中雷的个数；? 格（interval）的雷数落在 [lo, hi] 区间。
class_name ClassicConstraint
extends RefCounted


## 判断一个候选雷分布 mine_set 是否满足全部已翻开格约束。
## 签名与 BruteForceOracle.query 的 check 参数一致。
static func check(mine_set: Array[Vector2i], revealed: Dictionary, grid_size: Vector2i) -> bool:
	for pos in revealed:
		var c: Dictionary = revealed[pos]
		var cnt := 0
		for nb in _neighbors(pos, grid_size):
			if mine_set.has(nb):
				cnt += 1
		match c.get("type", ""):
			"equality":
				if cnt != c["value"]:
					return false
			"interval":
				if cnt < c["lo"] or cnt > c["hi"]:
					return false
	return true


static func _neighbors(pos: Vector2i, grid_size: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy: int in [-1, 0, 1]:
		for dx: int in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var nx: int = pos.x + dx
			var ny: int = pos.y + dy
			if nx >= 0 and nx < grid_size.x and ny >= 0 and ny < grid_size.y:
				out.append(Vector2i(nx, ny))
	return out
