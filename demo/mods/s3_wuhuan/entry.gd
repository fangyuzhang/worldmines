# entry.gd —— S3「无环」（v3.0 GDD §4.2 S3 / §4.5）
#
# 规则（KIND_GLOBAL）：把全部雷看作图的顶点，两个雷若互为八邻关系则连一条边，
# 所得图不含环（即为**森林**）：
#     K = { B : G_M = (M, {(p,q) : ‖p−q‖∞ = 1}) 是森林 }
#
# 作用域：拓扑。推理手感（GDD §4.5 原文）：等价于「雷的连通形态只能是树或链，不能成圈」。
# 排除某格时必须同时考虑连通性——把两颗原本分离的雷连通起来，有可能因此成环。属**拓扑推理**。
# 评分 C5 F4 L4 G3 D4。
#
# ★ 编码（本算子的核心难点与其解法）：
#   「无环」是**全局拓扑性质**，看似无法用局部线性约束表达。关键等价改写：
#     **森林 ⟺ 存在一个「父指针」赋值 + 层级函数 L，使每个雷要么是根（邻居层级都不小于它），
#       要么恰有一个层级严格更小的邻居作父。**
#   理由：① 若存在这样的赋值，沿父指针走 L 严格递减且有下界 ⇒ 必然终止 ⇒ 不可能有环；
#         ② 若图是森林，对每个分量取根并按 BFS 赋 L 即可构造出该赋值。
#   于是把全局性质化为**逐格局部约束**：
#     · 每格整数层级 L_p ∈ [0, R·C]（aux）
#     · 每格每邻居一个布尔 h_{p,q} = 「q 是 p 的父」
#     · h_{p,q} → B_p ∧ B_q ∧ (L_q + 1 ≤ L_p)          （父的层级严格更小）
#     · B_p → (Σ_q h_{p,q} = 1 − root_p)               （非根恰一父、根无父）
#     · root_p → (L_p ≤ L_q) 对所有邻居 q              （根是局部最小，封住「根也可有更小邻居」的漏）
#   变量规模：L 为 R·C 个整数、h 为 ≤ 8·R·C 个布尔、root 为 R·C 个布尔（9×9 → 约 800）。
#
# 构造式布雷（R03 红线）：GDD 为「逐颗加入 + **并查集**检测：若待加入位置的八邻域中存在
# 两个及以上**已属于不同连通块**的雷，则加入后会成环，回溯」。本实现即按此做随机贪心 + 重试。
# GDD 预警：40% 密度下森林形态相当稀疏，**小盘可能欠产**（由预检/量产实测确认）。
extends RefCounted


class NoCycleRule:
	extends RulePlugin

	const DIRS8 := [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	]

	func get_rule_id() -> StringName:
		return &"s3"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "无环",
			"rule_text": "雷只能连成链或树杈，不能围成一个闭合的圈",
		}

	func build_global_constraints(b: RuleBuilder) -> void:
		var n := b.rows
		var m := b.cols
		var span := n * m
		# 层级：0 表示非雷格（无意义）；雷格用 1..span。用 [0, span] 覆盖两种情形。
		var lvl: Array = []
		var root: Array = []
		for r in n:
			var row_l: Array = []
			var row_r: Array = []
			for c in m:
				row_l.append(b.int_var(0, span))
				row_r.append(b.bool_var())
			lvl.append(row_l)
			root.append(row_r)
		for r in n:
			for c in m:
				var mine := b.cell_var(r, c)
				var l_p: Dictionary = lvl[r][c]
				var root_p: Dictionary = root[r][c]
				var hs: Array = []
				var nbrs: Array = b.neighbors(Vector2i(c, r), DIRS8)
				for q in nbrs:
					var qv: Vector2i = q
					var h := b.bool_var()
					hs.append(h)
					var b_q := b.cell_var(qv.y, qv.x)
					# h → B_p ∧ B_q ∧ (L_q + 1 ≤ L_p)
					b.add_imp(h, mine)
					b.add_imp(h, b_q)
					b.add_le(b.lin([1], [lvl[qv.y][qv.x]], 1), l_p, [h])
					# root_p → L_p ≤ L_q
					b.add_le(l_p, lvl[qv.y][qv.x], [root_p])
				if hs.is_empty():
					continue
				# B_p → Σh = 1 − root_p
				b.add_eq(b.sum(hs), b.lin([-1], [root_p], 1), [mine])

	## 构造式布雷：逐颗加入 + 并查集环检测（GDD 指定方案）。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if count <= 0 or count > cols * rows:
			return []
		for _attempt in 200:
			var mines := _grow(rng, cols, rows, count)
			if mines.size() == count and _ok(mines):
				return mines
		return []

	## 随机逐颗加入：每放一颗前检查会不会成环（加入后其邻域内「已有雷的连通块数」是否 ≥ 2——
	## 若是，则该雷会把两个不同块连起来，必然成环）。
	static func _grow(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var cells: Array[Vector2i] = []
		for r in rows:
			for c in cols:
				cells.append(Vector2i(c, r))
		var order := cells.duplicate()
		for i in range(order.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var t = order[i]
			order[i] = order[j]
			order[j] = t
		var parent := {}
		var picked: Array[Vector2i] = []
		for p in order:
			if picked.size() >= count:
				break
			if _would_cycle(p, picked, parent):
				continue
			# 加入并合并其邻域内所有连通块
			picked.append(p)
			_union_neighbors(p, picked, parent)
		return picked

	## 并查集：find（带路径压缩，用 parent 字典；非根格存其父）。
	static func _find(parent: Dictionary, x: Vector2i) -> Vector2i:
		var cur := x
		while parent.has(cur) and parent[cur] != cur:
			cur = parent[cur]
		return cur

	static func _union(parent: Dictionary, a: Vector2i, bb: Vector2i) -> void:
		var ra := _find(parent, a)
		var rb := _find(parent, bb)
		if ra != rb:
			parent[rb] = ra

	## 加入 p 是否会成环：**邻域内存在两颗已属于同一连通块的雷** →
	## 它们之间已有路径，加上 (p, 雷₁)、(p, 雷₂) 两条新边恰好围成一个环。
	## 反例辨析（易错点）：邻域内有 ≥2 个**不同**连通块时**不会**成环——那只是把若干块连成一棵更大的树。
	static func _would_cycle(p: Vector2i, picked: Array[Vector2i], parent: Dictionary) -> bool:
		var roots: Array = []
		for d in NoCycleRule.DIRS8:
			var q: Vector2i = p + (d as Vector2i)
			if picked.has(q):
				var rq := _find(parent, q)
				if roots.has(rq):
					return true
				roots.append(rq)
		return false

	## 加入 p 后：把 p 与其邻域内已有的雷合并为同一块。
	static func _union_neighbors(p: Vector2i, picked: Array[Vector2i], parent: Dictionary) -> void:
		if not parent.has(p):
			parent[p] = p
		for d in NoCycleRule.DIRS8:
			var q: Vector2i = p + (d as Vector2i)
			if picked.has(q):
				_union(parent, p, q)

	## 全盘复核：八邻接图不含环（独立复算——对每个连通分量数「边数 = 点数 − 1」）。
	static func _ok(mines: Array[Vector2i]) -> bool:
		var ms := {}
		for m in mines:
			ms[m] = true
		var seen := {}
		for start in ms:
			if seen.has(start):
				continue
			# BFS 收集该分量
			var stack: Array = [start]
			seen[start] = true
			var verts := 0
			var edge_twice := 0
			while not stack.is_empty():
				var p: Vector2i = stack.pop_back()
				verts += 1
				for d in NoCycleRule.DIRS8:
					var q: Vector2i = p + (d as Vector2i)
					if ms.has(q):
						edge_twice += 1
						if not seen.has(q):
							seen[q] = true
							stack.append(q)
			# 森林的分量：边数（= edge_twice/2）必须恰为 顶点数 − 1
			if edge_twice / 2 != verts - 1:
				return false
		return true


func on_load() -> bool:
	RuleRegistry.default().register(NoCycleRule.new())

	return true