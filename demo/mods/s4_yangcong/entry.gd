# entry.gd —— S4「洋葱」（v3.0 GDD §4.2 S4 / §4.5）
#
# 规则（KIND_GLOBAL）：按每格到棋盘边界的**切比雪夫距离**把全盘分成若干环层（距离 0 = 第 0 层，
# 即最外圈；层号越大越靠内）。由外向内，各环层的**雷密度单调不减**：
#     m_0/|L_0| ≤ m_1/|L_1| ≤ … ≤ m_{T-1}/|L_{T-1}|
#   去分母后即线性不等式：|L_t| · m_{t+1} ≥ |L_{t+1}| · m_t。
#
# 作用域：全盘（分层）。推理手感（GDD §4.5 原文）：提供一条全局性**梯度先验**——外层雷密度
# 不高于内层。与 S2 重心的区别：约束的是**分层密度**而非一阶矩，两者可叠加但会显著收窄可行域。
#
# 各尺寸环层格数（GDD §4.5 表，t=0 为最外层）：
#   5×5 → 16/8/1（3 层）｜6×6 → 20/12/4（3 层）｜7×7 → 24/16/8/1（4 层）
#   8×8 → 28/20/12/4（4 层）｜9×9 → 32/24/16/8/1（5 层）
#   本插件用「距边界切比雪夫距离」直接算层，不硬编码，天然覆盖上述表值与异形盘的退化情形。
#
# 构造式布雷（R03 红线）：**按层由内到外分配雷数配额**（先满足最内层密度最高），层内随机布点。
#   配额算法：先按层容量比例取整分配，再迭代修正违序（把外层多余的雷搬向内层），保持总数不变。
extends RefCounted


class OnionRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"s4"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "洋葱",
			"rule_text": "越靠棋盘里面，雷就越密",
		}

	## 环层划分：按距边界的切比雪夫距离 d = min(r, rows-1-r, c, cols-1-c)。
	## 返回 [[层0 格子…], [层1 格子…], …]（层 0 = 最外层）。空层不会出现（矩形盘）。
	static func layers_of(rows: int, cols: int) -> Array:
		var nc := mini(rows, cols)
		var t_max := (nc - 1) / 2  # 最大层号（= GDD 表层数 − 1）
		var out: Array = []
		for t in t_max + 1:
			out.append([])
		for r in rows:
			for c in cols:
				var d := mini(mini(r, rows - 1 - r), mini(c, cols - 1 - c))
				(out[d] as Array).append(Vector2i(c, r))
		return out

	func build_global_constraints(b: RuleBuilder) -> void:
		var layers := layers_of(b.rows, b.cols)
		if layers.size() < 2:
			return
		for t in layers.size() - 1:
			var outer: Array = layers[t]      # 外层（t）
			var inner: Array = layers[t + 1]  # 内层（t+1）
			if outer.is_empty() or inner.is_empty():
				continue
			# |L_t| · m_{t+1} ≥ |L_{t+1}| · m_t   →   Σ ≥ 0
			#   用 lin 表达：内层每格系数 |L_t|，外层每格系数 −|L_{t+1}|
			var ws: Array = []
			var xs: Array = []
			for p in inner:
				ws.append(outer.size())
				xs.append(b.cell_var(p.y, p.x))
			for p in outer:
				ws.append(-inner.size())
				xs.append(b.cell_var(p.y, p.x))
			b.add_le(0, b.lin(ws, xs))

	## 构造式布雷：层配额（由内到外密度不增）+ 层内随机布点。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if count <= 0 or count > cols * rows:
			return []
		var total := cols * rows
		var layers := layers_of(rows, cols)
		var T := layers.size()
		var caps: Array[int] = []
		for t in T:
			caps.append((layers[t] as Array).size())
		var quota := _quota(caps, total, count, rng)
		if quota.is_empty():
			return []
		var out: Array[Vector2i] = []
		for t in T:
			var k: int = int(quota[t])
			if k <= 0:
				continue
			var pool: Array = (layers[t] as Array).duplicate()
			for i in range(pool.size() - 1, 0, -1):
				var j := rng.randi_range(0, i)
				var tmp = pool[i]
				pool[i] = pool[j]
				pool[j] = tmp
			if k > pool.size():
				return []
			for i in k:
				out.append(pool[i])
		return out

	## 层配额：先按容量比例取整，再迭代修正违序（密度须由外向内不降）——总和恒为 count。
	static func _quota(caps: Array[int], total: int, count: int, rng: RandomNumberGenerator) -> Array:
		var T := caps.size()
		var q: Array = []
		var acc := 0
		for t in T:
			var v := int(round(float(count) * float(caps[t]) / float(total)))
			q.append(v)
			acc += v
		# 补/减差额（随机选层，避免系统性偏置）
		var order: Array = []
		for t in T:
			order.append(t)
		while acc != count:
			for i in range(order.size() - 1, 0, -1):
				var j := rng.randi_range(0, i)
				var tmp = order[i]
				order[i] = order[j]
				order[j] = tmp
			var changed := false
			for t in order:
				if acc < count and int(q[t]) < caps[t]:
					q[t] = int(q[t]) + 1
					acc += 1
					changed = true
				elif acc > count and int(q[t]) > 0:
					q[t] = int(q[t]) - 1
					acc -= 1
					changed = true
				if acc == count:
					break
			if not changed:
				return []
		# 迭代修正：外层密度不得高于内层（违反则把外层的雷搬给内层）
		for _iter in 300:
			var bad := -1
			for t in T - 1:
				# m_t/|L_t| > m_{t+1}/|L_{t+1}|  →  越界
				if int(q[t]) * caps[t + 1] > int(q[t + 1]) * caps[t]:
					bad = t
					break
			if bad < 0:
				return q
			if int(q[bad]) <= 0 or int(q[bad + 1]) >= caps[bad + 1]:
				return []
			q[bad] = int(q[bad]) - 1
			q[bad + 1] = int(q[bad + 1]) + 1
		return []


func on_load() -> bool:
	RuleRegistry.default().register(OnionRule.new())

	return true