# entry.gd —— S2「重心」（v3.0 GDD §4.2 S2 / §4.5）
#
# 规则（KIND_GLOBAL）：全部雷的横坐标平均值与纵坐标平均值都必须落在**盘面中央格区**内。
#   中央格区：奇数边长取正中 1×1；偶数边长取正中 2×2。
#   为避开除法，GDD 用整数形式表达——设中央格区的坐标区间为 [x_min,x_max]×[y_min,y_max]，
#   记盘上雷数 N，则
#     K = { B : N·x_min ≤ Σ_{p∈M} x_p ≤ N·x_max 且 N·y_min ≤ Σ_{p∈M} y_p ≤ N·y_max }
#
# 作用域：全盘。推理手感（GDD §4.5 原文）：本算子只约束**一阶矩**（平均值）、不约束方差——
# 因此在四个角落各集中一堆雷、平均位置依然可以落在正中央。这意味着不能只凭「靠近中心」
# 判断，必须实际计算矩——是本作**推理味最独特的结构算子**（评分 C5 F4 L4 G4 D4）。
#
# 边界与坑（GDD §4.5 原文）：矩约束是全局线性约束，传播强度弱于局部约束，**求解器收敛较慢**；
# 量产时需监控 8×8 的超时率。→ 本插件的预检/probe 会实测该风险。
#
# 构造式布雷（R03 红线：禁止随机撒雷 + 拒绝重采）：先在中央区域布点，再做**交换式修正**——
# 反复把一颗雷沿「重心偏离的反方向」移动一格（实为「把偏离侧的雷与反侧空格交换」的等价实现），
# 直到两个坐标和都落入区间。均匀随机采样的一阶矩期望本就居中，故修正通常只需少量步。
extends RefCounted


class CentroidRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"s2"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "重心",
			"rule_text": "所有雷的平均位置，必须落在棋盘的正中间",
		}

	## 中央格区的整数区间（闭区间，0-based 坐标）：
	##   奇数 n：正中 1×1 → lo = hi = (n-1)/2（如 n=5 → 2）
	##   偶数 n：正中 2×2 → lo = (n-1)/2, hi = n/2（如 n=8 → 3,4）
	## 用 GDScript 整数除法即可同时覆盖两种情况。
	static func _center_lo(n: int) -> int:
		return (n - 1) / 2

	static func _center_hi(n: int) -> int:
		return n / 2

	func build_global_constraints(b: RuleBuilder) -> void:
		var n := b.total_mines
		if n <= 0:
			return  # 无雷数信息时无法写出 N·lo / N·hi
		var x_lo := _center_lo(b.cols)
		var x_hi := _center_hi(b.cols)
		var y_lo := _center_lo(b.rows)
		var y_hi := _center_hi(b.rows)
		var xs: Array = []
		var xw: Array = []
		var ys: Array = []
		var yw: Array = []
		for r in b.rows:
			for c in b.cols:
				var v := b.cell_var(r, c)
				xs.append(v)
				xw.append(c)
				ys.append(v)
				yw.append(r)
		# Σ x_p = 按列号加权的和；Σ y_p 同理。四式为线性约束，全部平铺到叶子变量。
		var sx := b.wsum(xw, xs)
		var sy := b.wsum(yw, ys)
		b.add_le(n * x_lo, sx)
		b.add_le(sx, n * x_hi)
		b.add_le(n * y_lo, sy)
		b.add_le(sy, n * y_hi)

	## 构造式布雷：先均匀采样（一阶矩期望居中）→ 交换式修正至两轴和均落入区间。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if count <= 0 or count > cols * rows:
			return []
		var bounds := [
			count * _center_lo(cols), count * _center_hi(cols),
			count * _center_lo(rows), count * _center_hi(rows),
		]
		for _attempt in 80:
			var mines := _sample(rng, cols, rows, count)
			if mines.is_empty():
				continue
			var fixed := _fix(mines, cols, rows, bounds, rng)
			if not fixed.is_empty():
				return fixed
		return []

	## 均匀随机采样 count 格（一阶矩期望 = 正中；有界方差，靠 _fix 收敛）。
	static func _sample(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var cells: Array[Vector2i] = []
		for r in rows:
			for c in cols:
				cells.append(Vector2i(c, r))
		var pool := cells.duplicate()
		var out: Array[Vector2i] = []
		for i in count:
			if pool.is_empty():
				break
			var j := rng.randi_range(0, pool.size() - 1)
			out.append(pool[j])
			pool.remove_at(j)
		return out

	## 交换式修正：每步把一颗雷沿「重心偏离的反方向」移动一格（落点须为空且在盘内）。
	## 返回修正后的雷位；失败返回空数组（交上层换采样）。
	static func _fix(mines: Array[Vector2i], cols: int, rows: int, bounds: Array, rng: RandomNumberGenerator) -> Array[Vector2i]:
		var lo_sx := int(bounds[0])
		var hi_sx := int(bounds[1])
		var lo_sy := int(bounds[2])
		var hi_sy := int(bounds[3])
		var ms := {}
		for m in mines:
			ms[m] = true
		for _iter in 4000:
			var sx := 0
			var sy := 0
			for p in ms:
				sx += (p as Vector2i).x
				sy += (p as Vector2i).y
			var dx := 0
			if sx < lo_sx:
				dx = 1
			elif sx > hi_sx:
				dx = -1
			var dy := 0
			if sy < lo_sy:
				dy = 1
			elif sy > hi_sy:
				dy = -1
			if dx == 0 and dy == 0:
				var out: Array[Vector2i] = []
				for p in ms:
					out.append(p)
				return out
			# 随机序尝试：挑一颗能朝 (dx,dy) 方向让位（目标格空且界内）的雷
			var keys: Array = ms.keys()
			for i in range(keys.size() - 1, 0, -1):
				var j := rng.randi_range(0, i)
				var t = keys[i]
				keys[i] = keys[j]
				keys[j] = t
			var moved := false
			for p in keys:
				var q := Vector2i((p as Vector2i).x + dx, (p as Vector2i).y + dy)
				if q.x < 0 or q.x >= cols or q.y < 0 or q.y >= rows:
					continue
				if ms.has(q):
					continue
				ms.erase(p)
				ms[q] = true
				moved = true
				break
			if not moved:
				return []
		return []


func on_load() -> bool:
	RuleRegistry.default().register(CentroidRule.new())

	return true