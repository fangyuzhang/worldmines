# entry.gd —— Z4「行列同序」（v3.0 GDD §4.2 Z4 / §4.5）
#
# 规则（KIND_GLOBAL）：对每一个序号 k，第 k 行的雷数等于第 k 列的雷数（仅适用于**方形棋盘**）：
#     K = { B : row_k = col_k, k = 0…n−1 }，要求 R = C = n
#
# 作用域：全盘（行列对偶）。推理手感（GDD §4.5 原文）：本算子是**行列对偶约束**，把行雷数序列
# 与列雷数序列绑定为同一个向量——确定某一行雷数的同时，对应列的雷数也随之确定，是一个
# **自共轭**问题（不是两个独立的一维问题）。评分 C4 F4 L4 G4 D4。
#
# 边界与坑（GDD §4.5）：
#   ① 只适用于方形盘（5×5~9×9 全满足）；非方形拓扑下不可用 → 本插件对方形以外直接返回空约束
#      （不施加任何限制 = 不误杀，由可行性/预检侧判定该组合不可用）。
#   ② 与镜像叠加会强制行雷数序列回文（可行域收窄，见 C03）——交组合判据处理。
#
# 编码：每个 k 一条线性等式（行和 = 列和），共 n 条——是最"直白"的守恒编码。
#
# 构造式布雷（R03 红线）：GDD 给的是「先采样行雷数序列，再按列余量逐行填充（带回退 DFS）」。
#   本实现用**按列余量降序的贪心填充**（Havel–Hakimi 思想）：行和序列即列和序列（自共轭），
#   逐行把该行的 r_k 颗雷放到「当前余量最大」的列上，能自然满足列配额；失败则重采样行序列。
extends RefCounted


class RowColMirrorRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"z4"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "行列同序",
			"rule_text": "从上往下数第 k 行的雷数，和从左往右数第 k 列的雷数一样多",
		}

	func build_global_constraints(b: RuleBuilder) -> void:
		if b.rows != b.cols:
			return  # 仅方阵；非方阵不施加约束（交组合/可行性侧判定不可用）
		for k in b.rows:
			var row_vars: Array = []
			var col_vars: Array = []
			for c in b.cols:
				row_vars.append(b.cell_var(k, c))
			for r in b.rows:
				col_vars.append(b.cell_var(r, k))
			b.add_eq(b.sum(row_vars), b.sum(col_vars))

	## 构造式布雷：采样行雷数序列（即列和序列）→ 按列余量降序贪心填充。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if cols != rows or count <= 0 or count > cols * rows:
			return []
		var n := rows
		for _attempt in 200:
			var rs := _sample_row_sums(rng, n, count)
			if rs.is_empty():
				continue
			var mines := _fill(rng, n, rs)
			if not mines.is_empty() and _ok(mines, n):
				return mines
		return []

	## 采样行和序列：均匀随机分配 count 到 n 行（每行 0..n），中段偏好使分布更自然。
	static func _sample_row_sums(rng: RandomNumberGenerator, n: int, count: int) -> Array:
		var rs: Array = []
		for i in n:
			rs.append(0)
		var remaining := count
		while remaining > 0:
			# 收集尚有容量的行，随机挑一个 +1
			var cands: Array = []
			for i in n:
				if int(rs[i]) < n:
					cands.append(i)
			if cands.is_empty():
				return []
			var pick: int = cands[rng.randi_range(0, cands.size() - 1)]
			rs[pick] = int(rs[pick]) + 1
			remaining -= 1
		return rs

	## 按列余量降序逐行填充：行 k 需要 rs[k] 颗，放到当前「还差最多」的列上。
	static func _fill(rng: RandomNumberGenerator, n: int, rs: Array) -> Array[Vector2i]:
		var col_need: Array = []
		for j in n:
			col_need.append(int(rs[j]))  # 列 j 还需 rs[j] 颗
		var out: Array[Vector2i] = []
		for k in n:
			var want: int = int(rs[k])
			if want > n:
				return []
			# 候选列：余量 > 0；按余量降序（同余量时随机打散，避免固定对角模式）
			var cols_idx: Array = []
			for j in n:
				if int(col_need[j]) > 0:
					cols_idx.append(j)
			for i in range(cols_idx.size() - 1, 0, -1):
				var t := rng.randi_range(0, i)
				var tmp = cols_idx[i]
				cols_idx[i] = cols_idx[t]
				cols_idx[t] = tmp
			cols_idx.sort_custom(func(a, b): return int(col_need[a]) > int(col_need[b]))
			if cols_idx.size() < want:
				return []
			for i in want:
				var j: int = cols_idx[i]
				col_need[j] = int(col_need[j]) - 1
				out.append(Vector2i(j, k))
		# 终检：所有列余量必须归零
		for j in n:
			if int(col_need[j]) != 0:
				return []
		return out

	## 全盘复核：每一行的雷数 == 对应列的雷数（独立于生成过程的终检）。
	static func _ok(mines: Array[Vector2i], n: int) -> bool:
		var row_cnt: Array = []
		var col_cnt: Array = []
		for i in n:
			row_cnt.append(0)
			col_cnt.append(0)
		var seen := {}
		for m in mines:
			if seen.has(m):
				return false
			seen[m] = true
			row_cnt[m.y] = int(row_cnt[m.y]) + 1
			col_cnt[m.x] = int(col_cnt[m.x]) + 1
		for i in n:
			if int(row_cnt[i]) != int(col_cnt[i]):
				return false
		return true


func on_load() -> void:
	RuleRegistry.default().register(RowColMirrorRule.new())
