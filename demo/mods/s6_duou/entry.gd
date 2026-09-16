# entry.gd —— S6「度偶数」（v3.0 GDD §4.2 S6 / §4.5）
#
# 规则（KIND_GLOBAL）：对每一颗雷，其**八邻域内的雷数**（该雷的度数 deg）均为偶数：
#     K = { B : ∀ p ∈ M, deg(p) ≡ 0 (mod 2) }，即 deg(p) ∈ {0,2,4,6,8}
#
# 作用域：逐点。推理手感（GDD §4.5 原文）：这是**奇偶约束**——可走模 2 传播，把每颗雷的邻域和
# 取奇偶，得到一组 GF(2) 上的线性方程；玩家可用「圈选一片区域做奇偶统计」的技巧解题，
# 手感与计数型完全不同（评分 C4 F4 L5 G4 D3）。
#
# 编码（GDD：「奇偶约束在 CP-SAT 中传播较强，生成友好」）：对每格 p 引入辅助整数 k_p ∈ [0,4]
# 表示 deg/2，并**仅在 p 为雷时**强制 deg(p) = 2·k_p——
#     B_p = 1  ⟹  Σ_{q∈N8(p)} B_q = 2·k_p
# 非雷格不受约束（其 deg 可任意奇偶）。deq ≤ 8 而 k ≤ 4，故 k 的上界恰为 4。
# 「仅当 B_p=1」用 RuleBuilder 的 enforce 参数（OnlyEnforceIf 语义）表达。
#
# 构造式布雷（R03 红线）：GDD 指明基元为「**3×3 环 + 隔 2 孤点**」——
#   · 3×3 环（8 格围一圈、中心留空）：角格度 2、边格度 4，**全为偶数**；
#   · 孤立雷（与任何雷都不八邻接）：度 0，偶数。
# 两族基元互不干扰的前提是**彼此间隔**（环与环、环与孤点、孤点与孤点都不得八邻接），
# 否则度数会被跨基元的相邻关系改变。故布局时逐个放置并即时校验「不破坏已放置部分的度数」，
# 最终再全盘复核一次。
extends RefCounted


class EvenDegreeRule:
	extends RulePlugin

	## 八邻域偏移（不含自身）。
	const DIRS8 := [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	]
	## 3×3 环：以 (r,c) 为左上角的 8 格（中心 (r+1,c+1) 留空）。
	const RING3 := [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(0, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2),
	]

	func get_rule_id() -> StringName:
		return &"s6"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "度偶数",
			"rule_text": "每颗雷周围挨着的雷，数量一定是偶数",
		}

	func build_global_constraints(b: RuleBuilder) -> void:
		for r in b.rows:
			for c in b.cols:
				var mine := b.cell_var(r, c)
				var deg := b.sum(b.cell_vars(b.neighbors(Vector2i(c, r), DIRS8)))
				# deg ≤ 8 → deg/2 ≤ 4
				var k := b.int_var(0, 4)
				# B_p = 1 ⟹ Σ 邻域 B = 2k
				b.add_eq(deg, b.lin([2], [k]), [mine])

	## 构造式布雷：基元组合（3×3 环 / L 三格 / 孤点），逐个放置并即时校验。
	## 为什么需要多种基元：小盘 + 中高雷数时「只用环」会剩大量孤点而无处安放
	## （如 6×6/14 雷 = 1 环 + 6 孤点，6×6 上环的外圈几乎全是邻域禁区，放不下 6 个互不邻接的孤点）。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if count <= 0 or count > cols * rows:
			return []
		for _attempt in 80:
			var mines := _build(rng, cols, rows, count)
			if mines.size() == count and _ok(mines, cols, rows):
				return mines
		return []

	## 布局：贪心放基元，优先环（8）> L（3）> 孤点（1），放置失败则降级到更小基元。
	## 剩余量不足最小基元（1）或无处可放时放弃本次（外层重试）。
	static func _build(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var ms := {}
		var remaining := count
		var guard := 0
		while remaining > 0:
			guard += 1
			if guard > count * 4 + 40:
				return []
			var placed := false
			# 环（8 格）：剩余足够时以较高概率尝试
			if remaining >= 8 and rng.randf() < 0.55:
				placed = _try_place_ring(ms, rng, cols, rows)
				if placed:
					remaining -= 8
			# L 三格：剩余 ≥3 时尝试
			if not placed and remaining >= 3:
				placed = _try_place_L(ms, rng, cols, rows)
				if placed:
					remaining -= 3
			# 孤点兜底
			if not placed:
				placed = _try_place_isolated(ms, rng, cols, rows)
				if placed:
					remaining -= 1
			if not placed:
				return []
		var out: Array[Vector2i] = []
		for p in ms:
			out.append(p)
		return out

	## L 三格（2×2 去一角）的 4 种朝向：每颗雷恰有 2 颗邻雷（度 2，偶数）。
	const L_SHAPES := [
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1)],
		[Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
	]

	## 尝试放置一个 L 三格：3 格须全空且不与已有雷邻接（含斜向）。
	static func _try_place_L(ms: Dictionary, rng: RandomNumberGenerator, cols: int, rows: int) -> bool:
		var cands: Array = []
		for r in range(0, rows - 1):
			for c in range(0, cols - 1):
				for shape in L_SHAPES:
					var cells: Array = []
					var ok := true
					for d in shape:
						var p := Vector2i(c + (d as Vector2i).x, r + (d as Vector2i).y)
						cells.append(p)
						if ms.has(p) or _has_neighbor_mine(ms, p):
							ok = false
							break
					if ok:
						cands.append(cells)
		if cands.is_empty():
			return false
		for p in (cands[rng.randi_range(0, cands.size() - 1)] as Array):
			ms[p] = true
		return true

	## 尝试放置一个 3×3 环：环的 8 格必须全部空且不与已有雷八邻接（含斜向）。
	## 注意中心格也必须**空**（否则中心雷会与环上 8 格相邻，改变度数）。
	static func _try_place_ring(ms: Dictionary, rng: RandomNumberGenerator, cols: int, rows: int) -> bool:
		var cands: Array = []
		for r in range(0, rows - 2):
			for c in range(0, cols - 2):
				var cells: Array = []
				for d in RING3:
					cells.append(Vector2i(c + d.x, r + d.y))
				cells.append(Vector2i(c + 1, r + 1))  # 中心（须空且不与新环自扰）
				var ok := true
				for p in cells:
					if ms.has(p):
						ok = false
						break
					if _has_neighbor_mine(ms, p):
						ok = false
						break
				if ok:
					cands.append(cells)
		if cands.is_empty():
			return false
		var pick: Array = cands[rng.randi_range(0, cands.size() - 1)]
		# 只把 8 个环格记为雷，中心格保持空
		for i in 8:
			ms[pick[i]] = true
		return true

	## 尝试放置一个孤立雷：该格及其八邻域内均无雷。
	static func _try_place_isolated(ms: Dictionary, rng: RandomNumberGenerator, cols: int, rows: int) -> bool:
		var cands: Array = []
		for r in rows:
			for c in cols:
				var p := Vector2i(c, r)
				if ms.has(p) or _has_neighbor_mine(ms, p):
					continue
				cands.append(p)
		if cands.is_empty():
			return false
		ms[cands[rng.randi_range(0, cands.size() - 1)]] = true
		return true

	static func _has_neighbor_mine(ms: Dictionary, p: Vector2i) -> bool:
		for d in DIRS8:
			if ms.has(Vector2i(p.x + d.x, p.y + d.y)):
				return true
		return false

	## 全盘复核：每颗雷的八邻域雷数均为偶数（独立于生成过程的终检）。
	static func _ok(mines: Array[Vector2i], cols: int, rows: int) -> bool:
		var ms := {}
		for m in mines:
			ms[m] = true
		for m in mines:
			var deg := 0
			for d in DIRS8:
				if ms.has(Vector2i(m.x + d.x, m.y + d.y)):
					deg += 1
			if deg % 2 != 0:
				return false
		return true


func on_load() -> void:
	RuleRegistry.default().register(EvenDegreeRule.new())
