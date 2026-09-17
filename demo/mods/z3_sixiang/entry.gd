# entry.gd —— Z3「四象」（v3.0 GDD §4.2 Z3 / §4.5）
#
# 规则（KIND_GLOBAL）：棋盘划分为四个象限后，四个象限内的雷数相等。
#   奇数边长：先剔除中轴行与中轴列，剩余四块雷数相等；
#   偶数边长：直接四等分，四块雷数相等。
#
# 作用域：全盘（象限）。评分 C3 F3 L4 G2 D3。
#
# 整除要求（GDD §4.5，**分尺寸必须分清**）：
#   5×5（各 4 格 / 中轴 9 格）：存在中轴雷数使 N−m_轴 ≡ 0 (mod 4) → **可行**（m_轴 取 2 或 6）
#   6×6（各 9 格 / 无中轴）：N ≡ 0 (mod 4) → **标准 14 不可行**，须回退 12 或 16
#   7×7（各 9 格 / 中轴 13 格）：**可行**（m_轴 取 0/4/8/12）
#   8×8（各 16 格 / 无中轴）：**不可行**（26 不整除），回退 24 或 28
#   → 偶数边长没有中轴吸收余数，是 P02 最典型的实例；本插件对不可行的 (盘, N) 直接返回空，
#     交上层雷数候选回退机制换值重试（**绝不偷偷调平雷数**——内置 qd 曾有 `count -= count % 4`
#     的历史 bug，会产出违反 R07 固定雷数红线的关，此处显式判不可行）。
#
# 本插件与内置 `qd`（四象）等价——独立成 `z3` 是为总表「四象（底座：经典）」集合提供稳定 id。
#
# 构造式布雷（R03 红线）：四象限各 k 雷 + 中轴（奇数盘）随机补齐剩余雷数。
#   **关键**：k 必须从**全部**合法值中随机取一个（不能取最小值）——内置 qd 的历史 bug 正是
#   「取第一个可行 k（恒为最小值）→ 雷几乎全堆在中央十字／中轴，四象限空空如也，不同种子
#   长得几乎一样」，多样性极差。
extends RefCounted


class FourQuadrantRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"z3"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "四象",
			"rule_text": "棋盘四个角上的区域，雷的数量一样多",
		}

	func build_global_constraints(b: RuleBuilder) -> void:
		var q: Array = [[], [], [], []]
		for r in b.rows:
			for c in b.cols:
				var qi := ConstraintEngine.quadrant_of(r, c, b.rows, b.cols)
				if qi >= 0:
					(q[qi] as Array).append(b.cell_var(r, c))
		b.add_eq(b.sum(q[0]), b.sum(q[1]))
		b.add_eq(b.sum(q[1]), b.sum(q[2]))
		b.add_eq(b.sum(q[2]), b.sum(q[3]))

	## 构造式布雷：四象限各 k 雷 + 中轴随机补齐。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if count <= 0 or count > cols * rows:
			return []
		var q: Array = [[], [], [], []]
		var cross: Array[Vector2i] = []
		for r in rows:
			for c in cols:
				var qi := ConstraintEngine.quadrant_of(r, c, rows, cols)
				if qi < 0:
					cross.append(Vector2i(c, r))
				else:
					(q[qi] as Array).append(Vector2i(c, r))
		# 偶数盘无中轴吸收余数 → 雷数必须是 4 的倍数
		if (rows % 2 == 0) and (cols % 2 == 0) and count % 4 != 0:
			return []
		var q_max: int = mini(mini((q[0] as Array).size(), (q[1] as Array).size()),
			mini((q[2] as Array).size(), (q[3] as Array).size()))
		# 收集**全部**合法 k 再随机取（避免内置 qd 的「恒取最小 k → 雷堆中央」历史 bug）
		var options: Array = []
		for k in range(q_max + 1):
			if 4 * k > count:
				break
			if count - 4 * k <= cross.size():
				options.append(k)
		if options.is_empty():
			return []
		var kk: int = options[rng.randi_range(0, options.size() - 1)]
		var rest: int = count - 4 * kk
		var mines := {}
		for i in 4:
			for m in _sample(rng, q[i], kk):
				mines[m] = true
		for m in _sample(rng, cross, rest):
			mines[m] = true
		var out: Array[Vector2i] = []
		for m in mines:
			out.append(m)
		return out

	static func _sample(rng: RandomNumberGenerator, cells: Array, k: int) -> Array:
		if k <= 0:
			return []
		var pool := cells.duplicate()
		for i in range(pool.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var t = pool[i]
			pool[i] = pool[j]
			pool[j] = t
		var out: Array = []
		for i in mini(k, pool.size()):
			out.append(pool[i])
		return out

	## 全盘复核：四象限雷数相等（独立于生成过程的终检）。
	static func _ok(mines: Array[Vector2i], cols: int, rows: int) -> bool:
		var cnt := [0, 0, 0, 0]
		for m in mines:
			var qi := ConstraintEngine.quadrant_of(m.y, m.x, rows, cols)
			if qi >= 0:
				cnt[qi] = int(cnt[qi]) + 1
		return cnt[0] == cnt[1] and cnt[1] == cnt[2] and cnt[2] == cnt[3]


func on_load() -> bool:
	RuleRegistry.default().register(FourQuadrantRule.new())

	return true