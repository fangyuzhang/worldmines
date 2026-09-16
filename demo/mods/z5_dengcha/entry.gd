# entry.gd —— Z5「等差行」（v3.0 GDD §4.2 Z5 / §4.5）
#
# 规则（KIND_GLOBAL）：自上而下各行的雷数按行序构成一个**等差数列**——
#   存在首项 a 与公差 d，使第 i 行（0-based）的雷数为 a + i·d，且每行雷数落在 [0, C] 内：
#     K = { B : ∃ a, d, row_i = a + i·d (∀i)，且 0 ≤ row_i ≤ C }
#
# 作用域：全盘（行序列）。评分 C4 F4 L4 G3 D4。
#
# 编码（**存在量词用 aux 变量表达**）：引入两个整数 aux——首项 a（∈[0,C]）与公差 d（∈[−C,C]），
#   然后对每行写一条线性等式 row_i = a + i·d。CP-SAT 会在求解时自行选定满足全部行的 (a,d)。
#
# 判别式（GDD §4.5 明确要求「直接实现这条判别式，而不是查表」）：
#     N ≡ 0 (mod gcd(R, R(R−1)/2))
#   即 5×5 要求 N 是 5 的倍数、6×6 是 3 的倍数、7×7 是 7 的倍数、8×8 是 4 的倍数。
#   **判别式必要非充分**：它只保证存在整数解 (a,d)，不保证每行雷数落在 [0,C]。故实现分两步：
#   ① 判别式 → ② 枚举 (a,d) 并逐行检查取值域。两者都过才产盘。
#
# 可行性（GDD §4.5 表）：**四尺寸中只有 5×5 在标准雷数下可行**（10 = 5·2 ⇒ a+2d=2，
# 如 (2,2,2,2,2) 或 (0,1,2,3,4)）；6×6/7×7/8×8 标准值分别须回退到 12/18、14/21、24/28。
#   不可行时本插件返回空，由上层雷数候选回退机制换值（**不偷偷调平雷数**）。
#
# 蕴含关系（GDD）：d = ±1 时**严格蕴含**相邻行锁（Z2）——二者不可同时选用（判据 J4）；
#   d = 0 时退化为「各行雷数相同」。
#
# 构造式布雷（R03 红线）：枚举 (a,d) 得行雷数序列 → 按各行配额采样。
extends RefCounted


class ArithmeticRowsRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"z5"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "等差行",
			"rule_text": "从上往下每一行的雷数，构成一个等差数列",
		}

	func build_global_constraints(b: RuleBuilder) -> void:
	# 行数 < 2 时任何行序列都是等差（退化为空约束）
		if b.rows < 2:
			return
		var a := b.int_var(0, b.cols)          # 首项
		var d := b.int_var(-b.cols, b.cols)    # 公差
		for i in b.rows:
			var rv: Array = []
			for c in b.cols:
				rv.append(b.cell_var(i, c))
			# row_i = a + i·d
			b.add_eq(b.sum(rv), b.lin([1, i], [a, d]))

	## 构造式布雷：① 判别式 → ② 枚举 (a,d) 查值域 → ③ 按行配额采样。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if rows < 2 or count <= 0 or count > cols * rows:
			return []
		# ① 判别式（必要非充分）
		var half := rows * (rows - 1) / 2
		if count % _gcd(rows, half) != 0:
			return []
		# ② 枚举全部合法 (a, d) 再随机取一个（避免固定模式）
		var opts: Array = []
		for d in range(-cols, cols + 1):
			var num := count - half * d
			if num % rows != 0:
				continue
			var a := num / rows
			if a < 0 or a > cols:
				continue
			var ok := true
			for i in rows:
				var ri := a + i * d
				if ri < 0 or ri > cols:
					ok = false
					break
			if ok:
				opts.append([a, d])
		if opts.is_empty():
			return []
		var pick: Array = opts[rng.randi_range(0, opts.size() - 1)]
		var a0: int = int(pick[0])
		var d0: int = int(pick[1])
		# ③ 按行配额随机采样
		var out: Array[Vector2i] = []
		for i in rows:
			var k: int = a0 + i * d0
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

	static func _gcd(x: int, y: int) -> int:
		var a := absi(x)
		var bb := absi(y)
		while bb != 0:
			var t := bb
			bb = a % bb
			a = t
		return maxi(a, 1)

	## 全盘复核：各行雷数构成等差数列（独立于生成过程的终检）。
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
		if rows < 2:
			return true
		var d: int = int(cnt[1]) - int(cnt[0])
		for i in rows - 1:
			if int(cnt[i + 1]) - int(cnt[i]) != d:
				return false
		return true


func on_load() -> void:
	RuleRegistry.default().register(ArithmeticRowsRule.new())
