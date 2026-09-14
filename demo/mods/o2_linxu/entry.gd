# entry.gd —— O2「邻序」（v3.0 GDD §4.2 O2 / §4.3）
#
# 规则：数字 = 八邻域内「经典雷数严格小于该格经典雷数」的格的个数。
# 雷格的经典雷数约定为 -1（使 f=0 ⟺ v=0，零值扩散与经典一致；GDD §4.3 已证）。
# 值域 0–8。全部格铺线索。
#
# 零值语义：可扩散（f=0 ⟺ 八邻无雷 → 八邻全安全，GDD §4.3）。
# 遮蔽：本版不启用（GDD 建议遮蔽形态 [1,8] 且禁遮蔽 0 值格；留待遮蔽机制完善后接入）。
# 构造式布雷：不需要（观测算子——随机布雷 + 线索正向计算）。
#
# 求解器编码（GDD §4.3「求解器编码」的线性等价；不引入需共享的 v 变量）：
#   对每有序对 (p,q)，q ∈ N₁(p)，引入 ℓ_pq ⟺ (v_q < v_p)，按格态三分：
#     a) p 是雷          → ℓ = 0（v_p = −1 最小，v_q ≥ −1 不严格小于）
#     b) p 非雷 ∧ q 是雷  → ℓ = 1（v_q = −1 < v_p，v_p ≥ 0）
#     c) p、q 均非雷      → ℓ ⟺ ΣN(q) ≤ ΣN(p) − 1（线性比较，双向各一条）
#   f_p = Σ_{q∈N₁(p)} ℓ_pq = value（本格线索）
#
# 本算子为 v3.0 换血第二个（S3 里程碑；GDD §8.2 可行性表全尺寸 ✓）。
extends RefCounted


class NeighborOrderRule:
	extends RulePlugin

	const NB8 := [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	]

	func get_rule_id() -> StringName:
		return &"o2"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "邻序",
			"rule_text": "数字表示八邻域内有多少个格子的雷数严格小于它自己；数字为 0 时八邻域全安全",
		}

	func applies_to(_pos: Vector2i, _grid_size: Vector2i) -> bool:
		return true

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		var vp := _v(mine_set, pos, grid_size)
		if vp < 0:
			return 0  # 防御：雷格不铺线索（生成器不会调用）
		var k := 0
		for d in NB8:
			var q: Vector2i = pos + d
			if q.x < 0 or q.x >= grid_size.x or q.y < 0 or q.y >= grid_size.y:
				continue
			if _v(mine_set, q, grid_size) < vp:
				k += 1
		return k

	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		# f=0 ⟺ v=0 ⟺ 八邻无雷（GDD §4.3：f≥1 当 v≥1，因雷邻 v=−1 < v_p）。
		if value == null or int(value) != 0:
			return []
		return dirs_to_neighbors(pos, grid_size, NB8)

	func value_upper_bound(_grid_size: Vector2i) -> int:
		return 8

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var bp := b.cell_var(pos.y, pos.x)
		var nbp := b.not_lit(bp)
		var ls: Array = []
		for q in b.neighbors(pos, NB8):
			var bq := b.cell_var(q.y, q.x)
			var nbq := b.not_lit(bq)
			var l := b.bool_var()
			b.add_eq(l, 0, [bp])                        # a) p 是雷 → ℓ=0
			b.add_eq(l, 1, [nbp, bq])                   # b) ¬B_p ∧ B_q → ℓ=1
			b.add_le(_nbr_diff(b, q, pos), -1, [nbp, nbq, l])            # c1) ¬B_p∧¬B_q∧ℓ → ΣN(q)−ΣN(p) ≤ −1
			b.add_le(_nbr_diff(b, pos, q), 0, [nbp, nbq, b.not_lit(l)])  # c2) ¬B_p∧¬B_q∧¬ℓ → ΣN(p)−ΣN(q) ≤ 0
			ls.append(l)
		b.add_eq(b.sum(ls), int(value))

	## Σ N(a) − Σ N(c) 的合并系数线性式（N(a) 各 +1、N(c) 各 −1，同格系数合并）。
	func _nbr_diff(b: RuleBuilder, a: Vector2i, c: Vector2i) -> Dictionary:
		var w: Dictionary = {}
		_bump(b, w, a, 1)
		_bump(b, w, c, -1)
		var ws: Array = []
		var xs: Array = []
		for t in w:
			var wi: int = int(w[t])
			if wi != 0:
				ws.append(wi)
				xs.append(b.cell_var(t.y, t.x))
		if ws.is_empty():
			return b.const_expr(0)
		return b.wsum(ws, xs)

	func _bump(b: RuleBuilder, w: Dictionary, center: Vector2i, sign: int) -> void:
		for d in NB8:
			var t: Vector2i = center + d
			if b.in_board(t.y, t.x):
				w[t] = int(w.get(t, 0)) + sign

	## 经典雷数 v（雷格约定 −1）。
	static func _v(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> int:
		if mine_set.has(pos):
			return -1
		var c := 0
		for d in NB8:
			var q: Vector2i = pos + d
			if q.x < 0 or q.x >= grid_size.x or q.y < 0 or q.y >= grid_size.y:
				continue
			if mine_set.has(q):
				c += 1
		return c


func on_load() -> void:
	RuleRegistry.default().register(NeighborOrderRule.new())
