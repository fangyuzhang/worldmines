# entry.gd —— O3「分档」（v3.0 GDD §4.2 O3 / §4.3）
#
# 规则：数字 = 该格雷数所属的档位（0–1→0，2–3→1，4–5→2，6–8→3）。值域 0–3。
# 零值语义：不可扩散（档 0 = 雷数 0 或 1——非安全信号，GDD §4.3 零值汇总表）。
# 遮蔽：本版不启用（GDD §6.2：档位少、遮蔽损失大，建议不启用）。
# 构造式布雷：效率布雷（低聚类+偏边缘加权采样，与 O1 同方案——观测算子通用）。
#
# 求解器编码（无辅助变量——v = ΣN B 是纯线性表达式）：
#   f = F ⟺ 2F ≤ ΣN B ≤ 2F+1（F=3 时为 ≥6 无上界）
#   下界 v ≥ 2F、上界 v ≤ 2F+1（F<3）——两条件即完整刻画（f 由 v 唯一决定：
#   区间内任意 v 的正向档位恰好为 F）。
#
# 本算子为 v3.0 换血第三个（S3 里程碑；GDD §8.2 可行性表全尺寸 ✓）。
extends RefCounted


class TierRule:
	extends RulePlugin

	const NB8 := [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	]

	func get_rule_id() -> StringName:
		return &"o3"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "分档",
			"rule_text": "数字表示雷数的档位：0–1→0，2–3→1，4–5→2，6–8→3（数字越小雷越少）",
		}

	func applies_to(_pos: Vector2i, _grid_size: Vector2i) -> bool:
		return true

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		var c := 0
		for d in NB8:
			var q: Vector2i = pos + d
			if q.x < 0 or q.x >= grid_size.x or q.y < 0 or q.y >= grid_size.y:
				continue
			if mine_set.has(q):
				c += 1
		return mini(c / 2, 3)   # 0–1→0，2–3→1，4–5→2，6–8→3

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var f := int(value)
		var sum_v := b.sum(b.cell_vars(b.neighbors(pos, NB8)))
		b.add_le(2 * f, sum_v)                       # 下界：v ≥ 2f
		if f < 3:
			b.add_le(sum_v, 2 * f + 1)               # 上界：v ≤ 2f+1（f=3 为 ≥6 无上界）

	func value_upper_bound(_grid_size: Vector2i) -> int:
		return 3

	func zero_safe_neighbors(_pos: Vector2i, _grid_size: Vector2i, _value: Variant = null) -> Array[Vector2i]:
		return []   # 档 0 含 0/1——不可扩散（GDD §4.3）

	## 效率布雷（与 O1 同方案——实测废品率 -54~-76%）：低聚类 + 偏边缘加权序列采样。
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
	RuleRegistry.default().register(TierRule.new())
