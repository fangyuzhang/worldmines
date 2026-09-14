# entry.gd —— O6「热度」（v3.0 GDD §4.2 O6 / §4.3）
#
# 规则：对八邻域内每颗雷，取其「邻雷数」（该雷的八邻域中的雷数）；数字 = 这些邻雷数的最大值。
# 八邻域内无雷时数字为 0。值域 0–8。全部格铺线索。
# 零值语义：可扩散（f=0 ⟺ 八邻无雷，GDD §4.3 已证；零值扩散邻域 = 八邻域）。
# 求解器编码（GDD §4.3：max + 选择器线性化）：
#   m_q（共享 int 变量，O2 基建 cell_int_var）：B_q → m_q = deg(q)；¬B_q → m_q = 0
#   f = max(m_q)：
#     · F ≥ m_q（∀q∈N₁(p)）
#     · F ≤ m_q + 8(1−e_q)（∀q），Σ e_q ≥ 1（至少一个 m_q 达到 F）
# 构造式布雷：效率布雷（与 O1 同方案）。
#
# 本算子为 v3.0 换血第六个（S3 里程碑；GDD §8.2 可行性表全尺寸 ✓；D 分最低=教学首曝）。
extends RefCounted


class HeatRule:
	extends RulePlugin

	const NB8 := [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	]

	func get_rule_id() -> StringName:
		return &"o6"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "热度",
			"rule_text": "数字表示它周围的雷里，周围雷最多的那一颗周围有几颗雷",
		}

	func applies_to(_pos: Vector2i, _grid_size: Vector2i) -> bool:
		return true

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		var best := 0
		for d in NB8:
			var q: Vector2i = pos + d
			if q.x < 0 or q.x >= grid_size.x or q.y < 0 or q.y >= grid_size.y:
				continue
			if not mine_set.has(q):
				continue
			var dg := 0
			for d2 in NB8:
				var s: Vector2i = q + d2
				if s.x < 0 or s.x >= grid_size.x or s.y < 0 or s.y >= grid_size.y:
					continue
				if mine_set.has(s):
					dg += 1
			best = maxi(best, dg)
		return best

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var f := int(value)
		var es: Array = []
		for q in b.neighbors(pos, NB8):
			var mq := _mq(b, q)
			b.add_le(mq, f)                              # F ≥ m_q
			var e := b.bool_var()
			# F ≤ m_q + 8(1−e_q)  ⟺  m_q − 8·e_q + 8 ≥ F
			b.add_le(b.lin([1, -8], [mq, e], 8), f)
			es.append(e)
		b.add_le(1, b.sum(es))                           # Σ e_q ≥ 1

	## 共享 m_q 变量（B_q → m_q = deg(q)；¬B_q → m_q = 0）。mark_once 保证每格初始化一次。
	func _mq(b: RuleBuilder, q: Vector2i) -> Dictionary:
		var m := b.cell_int_var(q.y, q.x, 0, 8)
		if not b.mark_once("mq|%d,%d" % [q.x, q.y]):
			return m
		var bq := b.cell_var(q.y, q.x)
		var deg := b.sum(b.cell_vars(b.neighbors(q, NB8)))
		b.add_eq(m, deg, [bq])
		b.add_eq(m, 0, [b.not_lit(bq)])
		return m

	func value_upper_bound(_grid_size: Vector2i) -> int:
		return 8

	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		# f=0 ⟺ 八邻无雷（GDD §4.3）——可扩散
		if value == null or int(value) != 0:
			return []
		return dirs_to_neighbors(pos, grid_size, NB8)

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


func on_load() -> void:
	RuleRegistry.default().register(HeatRule.new())
