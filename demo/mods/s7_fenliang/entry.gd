# entry.gd —— S7「分量数 K」（v3.0 GDD §4.2 S7 / §4.5）
#
# 规则（GDD 原文，KIND_GLOBAL）：全部雷构成的八连通块的数量**恰好等于 K**（K 为关卡参数）。
#     K = { B : ω(G_M) = K }
# 作用域：拓扑 + 基数。推理手感（GDD §4.5）：纯基数约束，规则一句话说清但推理不浅——
# 需同时判断「当前已有几块」与「剩余未定格会把块数改成多少」；K=1 退化为「全部雷连通」、
# K 接近上界退化为「雷高度分散」，**两端都偏易、中间取值最难**。评分 C4 F4 L5 G3 D3。
#
# K 的取值（GDD §4.5 设计取值范围，非可行性边界）：
#   5×5 → 1–4｜6×6 → 1–5｜7×7 → 1–6｜8×8 → 1–7｜（9×9 表未列，按趋势取 1–8）
#   本插件首版取各尺寸设计范围的**中低段**（K 越接近数学上界推理价值越低，见 GDD）。
#
# ★ 编码（连通性基数的难点与务实解法）：
#   精确表达「块数 = K」需要**连通分量计数**，是公认的编码难题（单商品流等方案变量/约束规模大，
#   9×9 上 CP-SAT 可能很慢）。本实现采用**保守编码**：
#     复用 S3「无环」的整套机制（父指针 + 严格递减层级 + 根标记）**保证每个分量是一棵树**
#     （每分量恰有一个根），再要求 **Σ root_p = K**。
#   · 正确性：根数 = 分量数（树的分量数与根数一一对应）⇒ **产出的盘块数确实等于 K**；
#   · 完备性：GDD 的规则允许「有环的块」——本编码额外要求无环，因此是规则的**严格子集**
#     ⇒ 会遗漏部分合法盘（欠产），但**绝不产非法解**。与 S5 同为保守编码，已在文档标注。
#
# 构造式布雷（R03 红线）：GDD 为「先确定 K，再逐个放置八连通块，每块强制不与已有块八邻接；
#   最后一块用剩余雷数填充」。本实现据此：前 K−1 块各取少量雷（随机树生长），最后一块吃掉
#   剩余雷数；生长时只允许加入「不与其它块八邻接」的格，从而保证块间分离。
extends RefCounted


class ComponentCountRule:
	extends RulePlugin

	const DIRS8 := [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	]
	## 各尺寸的设计取值范围中低段取值（GDD §4.5 表的「设计取值范围」中低段）。
	const K_BY_SIZE := {5: 2, 6: 3, 7: 3, 8: 4, 9: 4}

	func get_rule_id() -> StringName:
		return &"s7"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "分量数 K",
			"rule_text": "盘面上的雷，正好分成 K 坨",
		}

	func _k_for(n: int) -> int:
		return int(K_BY_SIZE.get(n, 4))

	func build_global_constraints(b: RuleBuilder) -> void:
		var n := b.rows
		var m := b.cols
		var span := n * m
		# 复用 S3 的机制：层级 + 父指针 + 根标记（保证每分量是树，故根数 == 分量数）
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
		var all_roots: Array = []
		for r in n:
			for c in m:
				var mine := b.cell_var(r, c)
				var l_p: Dictionary = lvl[r][c]
				var root_p: Dictionary = root[r][c]
				all_roots.append(root_p)
				var hs: Array = []
				var nbrs: Array = b.neighbors(Vector2i(c, r), DIRS8)
				for q in nbrs:
					var qv: Vector2i = q
					var h := b.bool_var()
					hs.append(h)
					var b_q := b.cell_var(qv.y, qv.x)
					b.add_imp(h, mine)
					b.add_imp(h, b_q)
					b.add_le(b.lin([1], [lvl[qv.y][qv.x]], 1), l_p, [h])
					b.add_le(l_p, lvl[qv.y][qv.x], [root_p])
				if hs.is_empty():
					continue
				b.add_eq(b.sum(hs), b.lin([-1], [root_p], 1), [mine])
		# Σ root_p = K（非雷格的 root 必须为 0，故用 enforce 由 B_p 控制）
		for r in n:
			for c in m:
				b.add_imp(root[r][c], b.cell_var(r, c))
		b.add_eq(b.sum(all_roots), _k_for(n))

	## 构造式布雷：K 个互不八邻接的块（前 K−1 块小、最后一块吃剩余雷数）。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var k := _k_for(rows)
		if count < k or count > cols * rows:
			return []
		for _attempt in 120:
			var mines := _build(rng, cols, rows, count, k)
			if mines.size() == count and _ok(mines, k):
				return mines
		return []

	static func _build(rng: RandomNumberGenerator, cols: int, rows: int, count: int, k: int) -> Array[Vector2i]:
		var ms := {}
		var remain := count
		for bi in k:
			var quota := 1
			if bi == k - 1:
				quota = remain  # 最后一块吃剩余
			else:
				var left_blocks := k - 1 - bi          # 之后还需留下的块数
				var max_q := remain - left_blocks      # 至少给后面的块各留 1
				if max_q < 1:
					return []
				quota = rng.randi_range(1, mini(3, max_q))
			if quota <= 0:
				return []
			if not _grow_block(rng, ms, cols, rows, quota):
				return []
			remain -= quota
			if remain < 0:
				return []
		var out: Array[Vector2i] = []
		for p in ms:
			out.append(p)
		return out

	## 生长一个连通块：随机种子 + 逐步加入「与块相邻、且不与其它块八邻接」的格。
	## 只加相邻格 ⇒ 块连通；每次只加一格 ⇒ 天然无环（树）。返回是否达到 quota。
	static func _grow_block(rng: RandomNumberGenerator, ms: Dictionary, cols: int, rows: int, quota: int) -> bool:
		# 收集可作种子的格：该格及其八邻域都无雷
		var seeds: Array = []
		for r in rows:
			for c in cols:
				var p := Vector2i(c, r)
				if ms.has(p) or _touches(ms, p):
					continue
				seeds.append(p)
		if seeds.is_empty():
			return false
		var block: Array = [seeds[rng.randi_range(0, seeds.size() - 1)]]
		ms[block[0]] = true
		while block.size() < quota:
			# 候选：与块相邻、不在块内、且其八邻域内既无「块内以外」的雷、也不与其它块相邻
			var cands: Array = []
			for p in block:
				for d in DIRS8:
					var q: Vector2i = (p as Vector2i) + (d as Vector2i)
					if q.x < 0 or q.x >= cols or q.y < 0 or q.y >= rows:
						continue
					if ms.has(q) or cands.has(q):
						continue
					# q 不得与「块外」的雷相邻（否则会与其它块合并）；与块内相邻是允许的（同一块）
					var ok := true
					for d2 in DIRS8:
						var z: Vector2i = q + (d2 as Vector2i)
						if ms.has(z) and not block.has(z):
							ok = false
							break
					if ok:
						cands.append(q)
			if cands.is_empty():
				return false
			var pick: Vector2i = cands[rng.randi_range(0, cands.size() - 1)]
			block.append(pick)
			ms[pick] = true
		return true

	static func _touches(ms: Dictionary, p: Vector2i) -> bool:
		for d in DIRS8:
			if ms.has(p + (d as Vector2i)):
				return true
		return false

	## 全盘复核：八连通块数恰为 K（独立复算）。
	static func _ok(mines: Array[Vector2i], k: int) -> bool:
		var ms := {}
		for m in mines:
			ms[m] = true
		var seen := {}
		var comps := 0
		for start in ms:
			if seen.has(start):
				continue
			comps += 1
			var stack: Array = [start]
			seen[start] = true
			while not stack.is_empty():
				var p: Vector2i = stack.pop_back()
				for d in DIRS8:
					var q: Vector2i = p + (d as Vector2i)
					if ms.has(q) and not seen.has(q):
						seen[q] = true
						stack.append(q)
		return comps == k


func on_load() -> bool:
	RuleRegistry.default().register(ComponentCountRule.new())

	return true