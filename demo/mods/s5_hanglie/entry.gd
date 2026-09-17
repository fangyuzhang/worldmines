# entry.gd —— S5「行列凸」（v3.0 GDD §4.2 S5 / §4.5）
#
# 规则（GDD 原文，KIND_GLOBAL）：对每个雷连通块，考察它在每一行、每一列上占据的格集合，
# 这些集合中的每一个都必须是**连续的一段**（中间不断开）。
#   · 空集约定（GDD 必须写死的约定）：某块在某行/某列不占据任何格时视为连续——
#     约束只在该块确实占据了该行/该列时才生效。
#   · 推理手感：比「矩形」宽松得多——实心块满足、十字形满足、阶梯形满足；
#     **L 形不满足**（某一行会断开）、**T 形不满足**。评分 C4 F4 L3 G3 D4。
#
# ★ 编码（本算子的难点与务实解法）：
#   GDD 指出「行列凸的 CP-SAT 编码比矩形复杂（需为每个分量维护端点区间变量），建议先用
#   构造式布雷产出候选，再用求解器验证」。真正的难点在于规则是**按连通块**陈述的，而
#   「哪几颗雷属于同一块」本身又是被求解的变量——无法直接写出「每块每行连续」。
#
#   本实现采用**保守编码**（GDD 规则的严格子集）：
#     把约束施加在**整盘**上——「每一行的雷连续」+「每一列的雷连续」。
#   · 正确性：整盘行列连续 ⇒ 每个连通块显然也行列连续 ⇒ **绝不产非法解**；
#   · 完备性：会**遗漏**「同一行上有两段雷、但分属不同块且各自连续」这类合法盘 ⇒ 欠产。
#     （GDD 规则允许该情形，保守编码不接受——这是本实现的已知取舍，已在文档标注。）
#
#   而「一维的雷连续」有一个**极简线性刻画**——禁止「1,0,1」空洞模式：
#         B(c) + B(c+2) − B(c+1) ≤ 1
#   对每行、每列各施一遍即可，无需任何 aux 变量。
#
# 构造式布雷（R03 红线）：「行区间沿行号单调」的形状天然行列连续——
#   取每行区间 [l_i, r_i]，令 l_i **非递增**、r_i **非递减**（区间自上而下向两侧张开，即阶梯形）：
#     · 行连续：每行取的是单个区间，天然成立；
#     · 列连续：第 c 列占用的行集合 = {i : l_i ≤ c ≤ r_i} = {i : i ≥ 阈值}（后缀），连续。
#   生成时对 l、r 做随机单调游走以取得形状多样性，雷数不对则重试。
extends RefCounted


class RowColConvexRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"s5"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "行列凸",
			"rule_text": "每一坨雷，在它经过的每一行和每一列上都不能断开",
		}

	func build_global_constraints(b: RuleBuilder) -> void:
		# 行连续：禁止 B(r,c)=1、B(r,c+1)=0、B(r,c+2)=1 的空洞模式
		for r in b.rows:
			for c in b.cols - 2:
				var v1 := b.cell_var(r, c)
				var v2 := b.cell_var(r, c + 1)
				var v3 := b.cell_var(r, c + 2)
				b.add_le(b.sum([v1, v3]), b.lin([1], [v2], 1))
		# 列连续：同一模式转置
		for c in b.cols:
			for r in b.rows - 2:
				var v1 := b.cell_var(r, c)
				var v2 := b.cell_var(r + 1, c)
				var v3 := b.cell_var(r + 2, c)
				b.add_le(b.sum([v1, v3]), b.lin([1], [v2], 1))

	## 构造式布雷：随机单调阶梯（l 非递增、r 非递减）+ 雷数校准重试。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if count <= 0 or count > cols * rows:
			return []
		if count < rows:
			return []  # 阶梯形每行至少 1 颗（区间非空）——更少的雷数需其它形状，交上层候选
		for _attempt in 300:
			var lr := _random_stairs(rng, cols, rows, count)
			if lr.is_empty():
				continue
			var mines := _materialize(lr[0], lr[1], rows)
			if mines.size() == count and _ok(mines, cols, rows):
				return mines
		return []

	## 随机单调阶梯：l 从某值非递增到 ≥0、r 从某值非递减到 ≤cols−1，且 l_i ≤ r_i，
	## 使 Σ(r_i − l_i + 1) == count；不命中则返回空（交调用方重试）。
	static func _random_stairs(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array:
		# 先造形状（随机游走），再按「当前总数」与目标之差做一次末端校准
		var l: Array = []
		var r: Array = []
		var l0 := rng.randi_range(0, cols - 1)
		var r0 := rng.randi_range(0, cols - 1)
		if l0 > r0:
			var t := l0
			l0 = r0
			r0 = t
		l.append(l0)
		r.append(r0)
		for i in range(1, rows):
			var nl: int = int(l[i - 1]) - rng.randi_range(0, 1)
			if nl < 0:
				nl = 0
			var nr: int = int(r[i - 1]) + rng.randi_range(0, 1)
			if nr > cols - 1:
				nr = cols - 1
			l.append(nl)
			r.append(nr)
		var total := 0
		for i in rows:
			if int(l[i]) > int(r[i]):
				return []
			total += int(r[i]) - int(l[i]) + 1
		var diff := count - total
		if diff == 0:
			return [l, r]
		# 校准：优先在最宽的行上扩/缩区间（保持 l 单调非增、r 单调非减）
		var guard := 0
		while diff != 0 and guard < 2000:
			guard += 1
			var i := rng.randi_range(0, rows - 1)
			if diff > 0:
				# 扩：向左或向右一格，需不破坏单调性
				var can_left: bool = int(l[i]) > 0 and (i == 0 or int(l[i]) - 1 >= int(l[i - 1]))
				var can_right: bool = int(r[i]) < cols - 1 and (i == rows - 1 or int(r[i]) + 1 <= int(r[i + 1]))
				if can_left and (not can_right or rng.randf() < 0.5):
					l[i] = int(l[i]) - 1
					diff -= 1
				elif can_right:
					r[i] = int(r[i]) + 1
					diff -= 1
			else:
				# 缩：向内一格（保持区间非空）
				if int(l[i]) < int(r[i]) and (i == rows - 1 or int(l[i]) + 1 <= int(l[i + 1])):
					l[i] = int(l[i]) + 1
					diff += 1
				elif int(r[i]) > int(l[i]) and (i == 0 or int(r[i]) - 1 >= int(r[i - 1])):
					r[i] = int(r[i]) - 1
					diff += 1
		if diff != 0:
			return []
		return [l, r]

	static func _materialize(l: Array, r: Array, rows: int) -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		for i in rows:
			var a: int = int(l[i])
			var bb: int = int(r[i])
			if a > bb:
				return []
			for c in range(a, bb + 1):
				out.append(Vector2i(c, i))
		return out

	## 全盘复核：每一行、每一列的雷都连续（独立复算）。
	static func _ok(mines: Array[Vector2i], cols: int, rows: int) -> bool:
		var ms := {}
		for m in mines:
			ms[m] = true
		for r in rows:
			var seen := false
			var closed := false
			for c in cols:
				if ms.has(Vector2i(c, r)):
					if closed:
						return false
					seen = true
				elif seen:
					closed = true
		for c in cols:
			var seen2 := false
			var closed2 := false
			for r in rows:
				if ms.has(Vector2i(c, r)):
					if closed2:
						return false
					seen2 = true
				elif seen2:
					closed2 = true
		return true


func on_load() -> bool:
	RuleRegistry.default().register(RowColConvexRule.new())

	return true