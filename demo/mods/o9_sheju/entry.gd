# entry.gd —— O9「射距」（v3.0 GDD §4.2 O9 / §4.3）
#
# 规则：沿上、下、左、右四条射线到盘边，记录每条射线第一颗雷的步数（无雷记「不通」）。
# 数字 = 四条射线首雷步数的最小值；四条射线全部不通显示 ∞。
# 值域 1..max(R,C)-1 或 ∞，**无 0 值**。频控：每盘 ∞ 格数 ≤ 2（标准密度天然发生率 0.007–0.062/盘，
# 上限几乎不触发——v1 不强制，由预检/生成观察）。
#
# 零值语义：无 0 值；∞ 的「整行整列清空规则」为 Board 层交互（与 O4 的 radius 渲染同类，
# 属后续里程碑）——本插件扩散返回空（不参与洪水扩散）。
#
# 求解器编码（线性，无 0 值参差）：
#   方向 dir 的射线格 c_1..c_m（由近及远，m_dir 随位置不同）。
#   前缀空链 e_j =「c_1..c_{j-1} 全空」（j=2..m+1；e_1 ≡ true 不建变量）：
#     e_{j+1} ≤ e_j；e_{j+1} ≤ 1−B_j；e_j − e_{j+1} − B_j ≤ 0（链）+ e_2 = 1−B_1（首格特例）。
#   f = d（整数）⟺
#     (1) 所有 m_dir ≥ d 的方向：e_dir[d] = 1（前 d−1 格全空——无更早命中，精确下界）；
#     (2) 所有 m_dir < d 的方向：e_dir[m+1] = 1（整条全空——否则该方向必产生 <d 的命中）；
#     (3) Σ_{m_dir ≥ d} B_dir[d] ≥ 1（至少一条射线第 d 格恰为雷——精确上界）。
#   链的单向传播证明：e[d]=1 经「e_j ≥ e_{j+1} − B_j」与「e_{j+1} ≤ 1 − B_j」反向归纳，
#   强制所有 j<d 的 B_j=0 与 e_j=1——下界完备。
#   f = ∞ ⟺ 所有方向：e_dir[m+1] = 1（穿过该格的整行整列无雷）。
#   所有线性式平铺到叶子变量（O4 教训：lin 的 xs 禁用嵌套表达式）。
#
# 构造式布雷：效率布雷（与 O1/O8 同方案——观测算子通用）。
extends RefCounted


class RayDistanceRule:
	extends RulePlugin

	## 四条射线的方向（上、下、左、右）。
	const RAY_DIRS := [
		Vector2i(0, -1),   # 上
		Vector2i(0, 1),    # 下
		Vector2i(-1, 0),   # 左
		Vector2i(1, 0),    # 右
	]

	const INF_SENTINEL := "inf"

	func get_rule_id() -> StringName:
		return &"o9"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "射距",
			"rule_text": "数字 = 沿上下左右走到最近雷的最短步数；∞ 表示四个方向一路到边都没有雷",
		}

	func applies_to(_pos: Vector2i, _grid_size: Vector2i) -> bool:
		return true

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		var best := 1 << 30
		for d in RAY_DIRS:
			var q: Vector2i = pos + d
			var step := 1
			while q.x >= 0 and q.x < grid_size.x and q.y >= 0 and q.y < grid_size.y:
				if mine_set.has(q):
					best = mini(best, step)
					break
				q += d
				step += 1
		if best >= (1 << 30):
			return INF_SENTINEL
		return best

	## 收集某方向的射线格（由近及远）。用 builder 的越界判定（与冻结的 spec 一致）。
	func _ray_cells(b: RuleBuilder, pos: Vector2i, d: Vector2i) -> Array:
		var out: Array = []
		var q: Vector2i = pos + d
		while b.in_board(q.y, q.x):
			out.append(q)
			q += d
		return out

	## 为一条射线建前缀空链，返回 e 数组（1-based：e[j] ≡「前 j-1 格全空」；e[1]=null≡true）。
	## 数组布局 [占位, e_1, e_2, ..., e_{m+1}]——e[j] 恰在 index j（首项占位保证 1-based 对齐）。
	func _build_chain(b: RuleBuilder, cells: Array) -> Array:
		var e: Array = [null, null]
		var prev: Variant = null
		for c in cells:
			var bj := b.cell_var(c.y, c.x)
			var ej := b.bool_var()
			if prev == null:
				# e_2 = 1 − B_1
				b.add_eq(b.lin([1, 1], [ej, bj]), 1)
			else:
				b.add_le(b.lin([1, -1], [ej, prev]), 0)          # e_j ≤ e_{j-1}
				b.add_le(b.lin([1, 1], [ej, bj]), 1)             # e_j + B ≤ 1
				b.add_le(b.lin([1, -1, -1], [prev, ej, bj]), 0)  # e_{j-1} − e_j − B ≤ 0
			e.append(ej)
			prev = ej
		return e

	static func _neg_ones(n: int) -> Array:
		var out: Array = []
		for _i in n:
			out.append(-1)
		return out

	## 线性编码（见文件头注释）。
	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var is_inf := false
		if value is String:
			is_inf = str(value) == INF_SENTINEL
		# 建四条链（整数与 ∞ 共用）。
		var chains: Array = []   # 每项 {cells: Array, e: Array}
		for d in RAY_DIRS:
			var cells := _ray_cells(b, pos, d)
			chains.append({"cells": cells, "e": _build_chain(b, cells)})

		if is_inf:
			for ch in chains:
				var cells: Array = ch["cells"]
				var e: Array = ch["e"]
				if cells.size() >= 1:
					b.add_eq(b.lin([1], [e[cells.size() + 1]]), 1)   # 整条全空
			return

		var d_val := int(value)
		if d_val < 1:
			return   # 防御：无 0 值语义（非法值不施加约束）
		var hit_cells: Array = []
		for ch in chains:
			var cells: Array = ch["cells"]
			var e: Array = ch["e"]
			var m := cells.size()
			if m >= d_val:
				if d_val > 1:
					b.add_eq(b.lin([1], [e[d_val]]), 1)             # 前 d−1 格全空
				hit_cells.append(b.cell_var(cells[d_val - 1].y, cells[d_val - 1].x))
			else:
				if m >= 1:
					b.add_eq(b.lin([1], [e[m + 1]]), 1)             # 整条全空
		if hit_cells.is_empty():
			# 防御分支（合法 d 必然存在 m_dir ≥ d 的方向）：施加矛盾使模型不可行。
			var probe := b.bool_var()
			b.add_eq(b.lin([1], [probe]), 1)
			b.add_eq(b.lin([1], [probe]), 0)
			return
		b.add_le(b.lin(_neg_ones(hit_cells.size()), hit_cells), -1)  # Σ B ≥ 1（至少一条第 d 格是雷）

	## 遮蔽不支持（离散码值无区间语义；GDD §4.4）。
	func supports_mask() -> bool:
		return false

	func value_upper_bound(grid_size: Vector2i) -> int:
		return maxi(grid_size.x, grid_size.y) - 1

	## 无 0 值——不参与洪水扩散（∞ 的整行整列清空为 Board 层规则，后续接线）。
	func zero_safe_neighbors(_pos: Vector2i, _grid_size: Vector2i, _value: Variant = null) -> Array[Vector2i]:
		return []

	## 效率布雷（与 O1/O8 同方案）：低聚类 + 偏边缘加权序列采样。
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
			for d in RAY_DIRS:
				var q: Vector2i = chosen + d
				if weights.has(q):
					weights[q] = maxf(0.05, float(weights[q]) * 0.35)
			for d in [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
				var qd: Vector2i = chosen + d
				if weights.has(qd):
					weights[qd] = maxf(0.05, float(weights[qd]) * 0.5)
		return out


func on_load() -> bool:
	RuleRegistry.default().register(RayDistanceRule.new())

	return true