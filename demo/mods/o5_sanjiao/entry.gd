# entry.gd —— O5「三角」（v3.0 GDD §4.2 O5 / §4.3）
#
# 规则：以该格为一个角，在 3×3 范围内可划出 4 个 2×2 区块（该格分别充当左上/右上/左下/右下角）。
# 数字 = 这 4 个区块中「除该格外的 3 格全为雷」的区块数。
# 值域 0–4（内部 4 个有效区块 / 边 2 个 / 角 1 个）。全部格铺线索。
#
# 零值语义：不可扩散（数字 0 只说明没有区块被填满，GDD §4.3）。
# 求解器编码（GDD §4.3 原方案）：每有效区块布尔 t_W：
#   t_W ≤ B_q（∀q∈W\{p}，用 add_imp）、t_W ≥ Σ_{W\{p}} B − 2（即 ΣB ≤ t_W + 2）
#   f = Σ t_W。每格至多 4 个布尔，开销极小。
# 构造式布雷：效率布雷（与 O1 同方案——观测算子通用）。
#
# 本算子为 v3.0 换血第四个（S3 里程碑；GDD §8.2 可行性表全尺寸 ✓）。
extends RefCounted


class TriangleRule:
	extends RulePlugin

	const NB8 := [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	]

	## 4 个 2×2 区块中「除 p 外的 3 格」的相对偏移（p 分别为左上/右上/左下/右下角）。
	const BLOCK_TRIPLES := [
		[Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],    # p 左上角
		[Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)],  # p 右上角
		[Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0)],  # p 左下角
		[Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(0, -1)], # p 右下角
	]

	func get_rule_id() -> StringName:
		return &"o5"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "三角",
			"rule_text": "数字表示它周围的四个小方块里，有几个小方块的另外三格全是雷",
		}

	func applies_to(_pos: Vector2i, _grid_size: Vector2i) -> bool:
		return true

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		var k := 0
		for triple in BLOCK_TRIPLES:
			var valid := true
			var r3 := 0
			for d in triple:
				var q: Vector2i = pos + d
				if q.x < 0 or q.x >= grid_size.x or q.y < 0 or q.y >= grid_size.y:
					valid = false
					break
				if mine_set.has(q):
					r3 += 1
			if valid and r3 == 3:
				k += 1
		return k

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var ts: Array = []
		for triple in BLOCK_TRIPLES:
			var valid := true
			var bs: Array = []
			for d in triple:
				var q: Vector2i = pos + d
				if not b.in_board(q.y, q.x):
					valid = false
					break
				bs.append(b.cell_var(q.y, q.x))
			if not valid:
				continue
			var t := b.bool_var()
			# t → 每个 B_q（t=1 时 3 格全雷）
			for bq in bs:
				b.add_imp(t, bq)
			# t ≥ ΣB − 2：ΣB=3 → t=1；ΣB≤2 → 无约束（t 可 0）
			b.add_le(b.sum(bs), b.lin([1], [t], 2))
			ts.append(t)
		b.add_eq(b.sum(ts), int(value))

	func value_upper_bound(_grid_size: Vector2i) -> int:
		return 4

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


func on_load() -> void:
	RuleRegistry.default().register(TriangleRule.new())
