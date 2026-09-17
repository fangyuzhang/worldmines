# entry.gd —— O8「钟点」（v3.0 GDD §4.2 O8 / §4.3）
#
# 规则：按方位编号表（1 正上、2 右上、3 正右、4 右下、5 正下、6 左下、7 正左、8 左上）
# 扫描八邻域中盘内的格，数字 = 第一颗雷所在的方位编号；八邻域无雷为 0。
# 越界方位跳过扫描但保留编号（角格只可能显示其可见方位号）。值域 {0} ∪ D_p。
#
# 零值语义：0 ⟺ 八邻域无雷 → 可扩散（八邻域，GDD §4.3）。
# 不参与遮蔽（GDD §4.4：离散码值无区间语义）。
#
# 求解器编码（前缀链，GDD §4.3 原方案）：
#   可见方位按编号序 c_1..c_m（m∈{3,5,8}）；B_j = c_j 是否雷。
#   前缀 z_j =「c_1..c_j 全非雷」：z_j ≤ z_{j-1}；z_j ≤ 1−B_j；z_j ≥ z_{j-1}−B_j。
#   指示 y_j =「首雷恰在 c_j」：y_j ≤ z_{j-1}；y_j ≤ B_j；y_j ≥ z_{j-1}+B_j−1。
#   等式 f = Σ v_j·y_j（v_j 为绝对方位编号）。
#   完备性：有雷 ⇒ 首雷位 y 被链下界强制=1（其余被上界夹 0）；value=0 ⇒ 强制全非雷。
#   所有线性式平铺到叶子变量（O4 教训：lin 的 xs 禁用嵌套表达式）。
#
# 构造式布雷：效率布雷（与 O1 同方案——观测算子通用）。
extends RefCounted


class ClockRule:
	extends RulePlugin

	## 方位编号表（GDD §2）：1 正上 … 8 左上，顺时针。
	const RING_DIRS := [
		Vector2i(0, -1),   # 1 正上
		Vector2i(1, -1),   # 2 右上
		Vector2i(1, 0),    # 3 正右
		Vector2i(1, 1),    # 4 右下
		Vector2i(0, 1),    # 5 正下
		Vector2i(-1, 1),   # 6 左下
		Vector2i(-1, 0),   # 7 正左
		Vector2i(-1, -1),  # 8 左上
	]

	func get_rule_id() -> StringName:
		return &"o8"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "钟点",
			"rule_text": "数字是方位密码：按「上、右上、右、右下、下、左下、左、左上」的顺序，第一颗雷在哪个方向就是几；0 表示一圈都没有雷",
		}

	func applies_to(_pos: Vector2i, _grid_size: Vector2i) -> bool:
		return true

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		for i in RING_DIRS.size():
			var q: Vector2i = pos + RING_DIRS[i]
			if q.x < 0 or q.x >= grid_size.x or q.y < 0 or q.y >= grid_size.y:
				continue
			if mine_set.has(q):
				return i + 1
		return 0

	## 前缀链编码（见文件头注释）。
	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var ys: Array = []
		var vs: Array = []
		var z_prev: Variant = null   # null ≡ 常量 true（z_0）
		for i in RING_DIRS.size():
			var q: Vector2i = pos + RING_DIRS[i]
			if not b.in_board(q.y, q.x):
				continue
			var bj := b.cell_var(q.y, q.x)
			var zj := b.bool_var()
			var yj := b.bool_var()
			if z_prev == null:
				# z_1 = ¬B_1：z_1 + B_1 = 1
				b.add_eq(b.lin([1, 1], [zj, bj]), 1)
				# y_1 = B_1：y_1 − B_1 = 0
				b.add_eq(b.lin([1, -1], [yj, bj]), 0)
			else:
				# z_j ≤ z_{j-1}
				b.add_le(b.lin([1, -1], [zj, z_prev]), 0)
				# z_j ≤ 1 − B_j：z_j + B_j ≤ 1
				b.add_le(b.lin([1, 1], [zj, bj]), 1)
				# z_j ≥ z_{j-1} − B_j：−z_j + z_{j-1} − B_j ≤ 0
				b.add_le(b.lin([-1, 1, -1], [zj, z_prev, bj]), 0)
				# y_j ≤ z_{j-1}
				b.add_le(b.lin([1, -1], [yj, z_prev]), 0)
				# y_j ≤ B_j
				b.add_le(b.lin([1, -1], [yj, bj]), 0)
				# y_j ≥ z_{j-1} + B_j − 1：−y_j + z_{j-1} + B_j ≤ 1
				b.add_le(b.lin([-1, 1, 1], [yj, z_prev, bj]), 1)
			ys.append(yj)
			vs.append(i + 1)
			z_prev = zj
		# f = Σ v_j · y_j（平铺到叶子变量）
		b.add_eq(b.lin(vs, ys), int(value))

	## 遮蔽不支持（GDD §4.4：离散码值无区间语义）。
	func supports_mask() -> bool:
		return false

	func value_upper_bound(_grid_size: Vector2i) -> int:
		return 8

	## 0 ⟺ 八邻域无雷 → 可扩散（八邻域）。
	## ⚠️ 必须判 value：非 0 值意味着「环上确有雷」，此时一个方向都不能当安全扩散
	## （与 loopruns 的零值修复同族——忽略 value 会让 Board 的洪水扩散把雷格也翻开）。
	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		if value != null:
			if value is int:
				if int(value) != 0:
					return out
			elif value is String:
				return out      # "inf"（首雷无雷哨兵）不参与扩散
			else:
				return out      # 数组/畸形值一律不扩散
		for d in RING_DIRS:
			var q: Vector2i = pos + d
			if q.x >= 0 and q.x < grid_size.x and q.y >= 0 and q.y < grid_size.y:
				out.append(q)
		return out

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
			for d in RING_DIRS:
				var q: Vector2i = chosen + d
				if weights.has(q):
					weights[q] = maxf(0.05, float(weights[q]) * 0.35)
		return out


func on_load() -> bool:
	RuleRegistry.default().register(ClockRule.new())

	return true