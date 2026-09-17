# entry.gd —— Z2「相邻行锁」（v3.0 GDD §4.2 Z2 / §4.5）
#
# 规则（KIND_GLOBAL）：任意上下相邻的两行，其雷数之差的**绝对值等于 1**：
#     K = { B : |row_{i+1} − row_i| = 1, i = 0…R−2 }
#
# 作用域：全盘（行序列）。推理手感（GDD §4.5 原文）：把二维布局压缩成一维序列问题——先解出
# 各行雷数序列，再回到二维确定每颗雷的位置，属**两阶段推理**。评分 C4 F4 L4 G3 D3。
#
# 奇偶性（GDD 给出的重要可行性结论）：设 row_i = a + s_i（s_0 = 0、s_i ≡ i (mod 2)），则
#     N = Σ row_i = R·a + Σ s_i，且 Σ s_i ≡ R(R−1)/2 (mod 2)
#   → 由此各尺寸对总雷数 N 有**奇偶要求**。**6×6 的 R(R−1)/2 = 15 为奇数 ⇒ N 必须为奇数**，
#     标准雷数 14 **不可满足**，须由雷数候选列表回退到 13 或 15（GDD §8.2，P02 实例）。
#   本插件的 place_mines 对不可满足的 (n, count) 直接返回空 —— 由上层候选回退机制换值重试，
#   不在插件内私改雷数（保持「雷数契约」单一真值）。
#
# 编码：绝对值不能直接写成线性式，故为每对相邻行引入一个**方向布尔 d_i**：
#     row_{i+1} − row_i = 2·d_i − 1      （d_i = 0 → −1；d_i = 1 → +1）
# 又因行和本身是表达式（不能作为 lin 的 xs），先给每行挂一个整数 aux R_i ∈ [0,cols] 承载行和。
#
# 构造式布雷（R03 红线）：GDD 为「行雷数序列做 DFS（每步 ±1），再按各行配额采样」。
extends RefCounted


class AdjacentRowLockRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"z2"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "相邻行锁",
			"rule_text": "上下相邻的两行，雷的数量一定差 1",
		}

	func build_global_constraints(b: RuleBuilder) -> void:
		if b.rows < 2:
			return
		# 每行挂一个整数 aux 承载行和（lin 的 xs 只接受变量引用/常量，不能直接吃 sum 表达式）
		var rows_aux: Array = []
		for i in b.rows:
			var rv: Array = []
			for c in b.cols:
				rv.append(b.cell_var(i, c))
			var aux := b.int_var(0, b.cols)
			b.add_eq(aux, b.sum(rv))
			rows_aux.append(aux)
		for i in b.rows - 1:
			var d := b.bool_var()  # 方向：0 → 差 −1；1 → 差 +1
			# R_{i+1} − R_i − 2d + 1 = 0  ⟺  R_{i+1} − R_i = 2d − 1
			b.add_eq(b.lin([1, -1, -2], [rows_aux[i + 1], rows_aux[i], d], 1), 0)

	## 构造式布雷：行雷数序列（DFS，每步 ±1，和 = count）→ 按每行配额随机采样。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if rows < 2 or count <= 0 or count > cols * rows:
			return []
		for _attempt in 60:
			var rs := _row_sums(rng, rows, cols, count)
			if rs.is_empty():
				return []  # 该 (尺寸, 雷数) 在奇偶上不可满足 → 交上层候选回退（不私改雷数）
			var mines := _fill(rng, cols, rs)
			if not mines.is_empty() and _ok(mines, rows):
				return mines
		return []

	## 行雷数序列：DFS（每步 ±1，值域 [0, cols]，和恰为 count）。
	## 起点随机、每步方向随机，找到一条即返回（搜索空间小：R ≤ 9、值域 ≤ 9）。
	static func _row_sums(rng: RandomNumberGenerator, rows: int, cols: int, count: int) -> Array:
		var starts: Array = []
		for v in range(0, cols + 1):
			starts.append(v)
		for i in range(starts.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var t = starts[i]
			starts[i] = starts[j]
			starts[j] = t
		for s in starts:
			var seq: Array = [int(s)]
			if _dfs_seq(rng, cols, count, seq, rows, int(s), int(s)):
				return seq
		return []

	## 递归搜索：已放置 depth 个行和、当前和为 acc、末值为 last。
	static func _dfs_seq(rng: RandomNumberGenerator, cols: int, count: int, seq: Array, rows: int, acc: int, last: int) -> bool:
		var placed := seq.size()
		if placed == rows:
			return acc == count
		# 剩余行数能贡献的最小/最大总和（每步 ±1，值域 [0,cols]）
		var rem := rows - placed
		var dirs: Array = [1, -1]
		if rng.randf() < 0.5:
			dirs = [-1, 1]
		for d in dirs:
			var nxt: int = last + int(d)
			if nxt < 0 or nxt > cols:
				continue
			var new_acc: int = acc + nxt
			# 剪枝：剩余 rem−1 行在 [0,cols] 内且每步 ±1，粗略界
			if new_acc > count:
				continue
			if new_acc + (rem - 1) * cols < count:
				continue
			seq.append(nxt)
			if _dfs_seq(rng, cols, count, seq, rows, new_acc, nxt):
				return true
			seq.pop_back()
		return false

	## 按行配额随机采样（每行取 rs[i] 个不同列）。
	static func _fill(rng: RandomNumberGenerator, cols: int, rs: Array) -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		for i in rs.size():
			var k := int(rs[i])
			if k < 0 or k > cols:
				return []
			var pool: Array = []
			for c in cols:
				pool.append(c)
			for x in range(pool.size() - 1, 0, -1):
				var j := rng.randi_range(0, x)
				var t = pool[x]
				pool[x] = pool[j]
				pool[j] = t
			for x in k:
				out.append(Vector2i(pool[x], i))
		return out

	## 全盘复核：相邻两行雷数之差的绝对值恒为 1。
	static func _ok(mines: Array[Vector2i], rows: int) -> bool:
		var cnt: Array = []
		for i in rows:
			cnt.append(0)
		var seen := {}
		for m in mines:
			if seen.has(m):
				return false
			seen[m] = true
			cnt[m.y] = int(cnt[m.y]) + 1
		for i in rows - 1:
			if absi(int(cnt[i + 1]) - int(cnt[i])) != 1:
				return false
		return true


func on_load() -> bool:
	RuleRegistry.default().register(AdjacentRowLockRule.new())

	return true