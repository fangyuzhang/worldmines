# entry.gd —— O7「奇显」（v3.0 GDD §4.2 O7 / §4.3）
#
# 规则：v = 八邻雷数。v 为奇数 → 显示 v；v 为偶数 → 留空（不显示数字）。
# 值域 {空, 1, 3, 5, 7}——「空」在本实现中用 **-1** 表示（落盘/校验约定）。
# 零值语义：不可扩散（「空」含 0/2/4/6/8——含 2+ 的偶数非安全，GDD §4.3）。
# 遮蔽：不启用（GDD 约定：奇显关不启用遮蔽，二选一）。
# 构造式布雷：效率布雷（与 O1 同方案）。
#
# 求解器编码：
#   v = ΣN B（八邻雷数和，纯线性表达式）
#   · 显示奇数值 F（F∈{1,3,5,7}）→ v = F（等式约束——奇数精确）
#   · 空（F=-1）→ v 为偶数：引入 int 辅助 t∈[0,4]，约束 v = 2t
#     （CP-SAT 侧 int aux 支持；GDScript 侧黑盒求值已改为「雷格 -1 对 v 等效」的直算路径，
#      本算子的值仅用「正向 compute_clue」，无需黑盒辅助变量求值）
#
# 本算子为 v3.0 换血第五个（S3 里程碑；GDD §8.2 可行性表全尺寸 ✓）。
extends RefCounted


class OddDisplayRule:
	extends RulePlugin

	const NB8 := [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	]

	func get_rule_id() -> StringName:
		return &"o7"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "奇显",
			"rule_text": "雷数是奇数的会显示出来，是偶数的就空着（空 = 偶数雷数）",
		}

	func applies_to(_pos: Vector2i, _grid_size: Vector2i) -> bool:
		return true

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		var v := 0
		for d in NB8:
			var q: Vector2i = pos + d
			if q.x < 0 or q.x >= grid_size.x or q.y < 0 or q.y >= grid_size.y:
				continue
			if mine_set.has(q):
				v += 1
		return v if v % 2 == 1 else -1   # 奇数显示 v；偶数返回 -1（空）

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var f := int(value)
		var sum_v := b.sum(b.cell_vars(b.neighbors(pos, NB8)))
		if f >= 0:
			# 奇数精确值：v = F
			b.add_eq(sum_v, f)
		else:
			# 空（偶数）：v = 2t（t 辅助整数，0..4）
			var t := b.int_var(0, 4)
			b.add_eq(sum_v, b.lin([2], [t]))

	func value_upper_bound(_grid_size: Vector2i) -> int:
		return 7

	func zero_safe_neighbors(_pos: Vector2i, _grid_size: Vector2i, _value: Variant = null) -> Array[Vector2i]:
		return []   # 不可扩散（GDD §4.3）

	## 效率布雷（与 O1 同方案）：低聚类 + 偏边缘加权序列采样。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var weights: Dictionary = {}
		for r in rows:
			for c in cols:
				var edge := c == 0 or r == 0 or c == cols - 1 or r == rows - 1
				weights[Vector2i(c, r)] = 1.25 if edge else 1.0
		var out: Array[Vector2i] = []
		for _i in count:
			var total := 0.0
			for p in weights:
				total += float(weights[p])
			if total <= 0.0:
				break
			var pick := rng.randf() * total
			var acc := 0.0
			var chosen := Vector2i(-1, -1)
			for p in weights:
				acc += float(weights[p])
				if acc >= pick:
					chosen = p
					break
			if chosen.x < 0:
				break
			out.append(chosen)
			weights.erase(chosen)
			for d in NB8:
				var q: Vector2i = chosen + d
				if weights.has(q):
					weights[q] = maxf(0.05, float(weights[q]) * 0.35)
		return out


func on_load() -> bool:
	RuleRegistry.default().register(OddDisplayRule.new())

	return true