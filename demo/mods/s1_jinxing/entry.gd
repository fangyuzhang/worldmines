# entry.gd —— S1「局部禁形」（v3.0 GDD §4.2 S1 / §4.5）
#
# 规则（KIND_GLOBAL）：棋盘上任意一个 2×2 区块内的雷数不超过 2。
#   K = { B : ∀ 2×2 窗口 W，Σ_{q∈W} B_q ≤ 2 }
#
# 作用域：局部窗口。推理手感：密度上限约束——某 2×2 区块已确定有 2 雷时，其内其余两格
# 必为安全格。存在感强但推理深度浅（GDD 评分 C2 F2 L5 G5 D2）。
# **边界与坑（GDD §4.5 原文）**：约束使可行域明显收缩、ρ 较小，结构本身提供了较多
# 「免费信息」，需注意难度被低估。
#
# 为什么独立成插件：本项目的自举式规则平台要求「平台自己能做到的，创作者都能做到」
# （core/rule_registry.gd 顶部）。本规则与内置 `pf`（禁形）等价，但**总表按
# 「局部禁形（底座：经典）」编制关卡集**，需要 `s1` 这一稳定 id 供批量/门禁/登记对齐。
#
# 构造式布雷（R03 红线：官方关禁止随机撒雷 + 拒绝重采）：分层采样优先 + 随机过滤兜底。
# 大密度（8×8/26 雷 = 40.6%）下纯随机单次全窗口过滤通过率极低（内置 pf 首轮量产实测
# 接受率 ~2.5%），根因是随机布雷易团簇 → 某 2×2 窗口 3+ 雷概率高。分层采样按对齐 2×2
# 块均衡分配（每块 ≤2 雷 → 对齐窗口必过，仅跨界窗口可能违约需 _ok 过滤），通过率高一个量级。
extends RefCounted


class LocalForbiddenRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"s1"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "局部禁形",
			"rule_text": "任意四个格组成的小方块里，最多只能有 2 颗雷",
		}

	func build_global_constraints(b: RuleBuilder) -> void:
		for r in b.rows - 1:
			for c in b.cols - 1:
				var quad := [
					b.cell_var(r, c), b.cell_var(r, c + 1),
					b.cell_var(r + 1, c), b.cell_var(r + 1, c + 1),
				]
				b.add_le(b.sum(quad), 2)

	## 构造式布雷：分层采样（对齐 2×2 块均衡）优先，纯随机 + 过滤兜底。
	## 两种路径都经 _ok 全窗口校验，语义一致；随机性全部走 _rng（确定性不受影响）。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		for _attempt in 200:
			var mines := _stratified_mines(rng, cols, rows, count)
			if not mines.is_empty() and _ok(mines, cols, rows):
				return mines
		for _attempt in 300:
			var mines := _random_mines(rng, cols, rows, count)
			if _ok(mines, cols, rows):
				return mines
		return []

	## 分层采样：雷按对齐 2×2 块均衡分配（每块 ≤ min(2, 块容量)），块内随机取位。
	## count 超过总容量（块数×2）时返回空（该密度下约束本就不可满足，交上层兜底）。
	static func _stratified_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var nby := ceili(rows / 2.0)
		var nbx := ceili(cols / 2.0)
		var blocks: Array = []
		var caps: Array[int] = []
		for by in nby:
			for bx in nbx:
				var cells: Array = []
				for r in range(by * 2, mini(by * 2 + 2, rows)):
					for c in range(bx * 2, mini(bx * 2 + 2, cols)):
						cells.append(Vector2i(c, r))
				blocks.append(cells)
				# 容量：满 2×2 块给 2 雷；边缘残块（1×2/2×1/1×1）只给 1——残块满填会与
				# 相邻块边界组成 3+ 雷窗口（内置 pf 在 9×9 实测通过率仅 3% 的根因）。
				var is_full_block: bool = (cells.size() == 4)
				caps.append(2 if is_full_block else 1)
		var total_cap := 0
		for cap in caps:
			total_cap += cap
		if count > total_cap:
			return []
		# 随机块序轮流分配（每轮每块 +1、到 cap 为止）→ 块间均衡且带随机性
		var order: Array[int] = []
		for i in blocks.size():
			order.append(i)
		for i in range(order.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var t := order[i]
			order[i] = order[j]
			order[j] = t
		var alloc: Array[int] = []
		for i in blocks.size():
			alloc.append(0)
		var remaining := count
		while remaining > 0:
			var progressed := false
			for bi in order:
				if remaining <= 0:
					break
				if alloc[bi] < caps[bi]:
					alloc[bi] += 1
					remaining -= 1
					progressed = true
			if not progressed:
				return []
		var out: Array[Vector2i] = []
		for bi in blocks.size():
			if alloc[bi] <= 0:
				continue
			var pool: Array = blocks[bi].duplicate()
			for i in range(pool.size() - 1, 0, -1):
				var j2 := rng.randi_range(0, i)
				var t2 = pool[i]
				pool[i] = pool[j2]
				pool[j2] = t2
			for i in alloc[bi]:
				out.append(pool[i])
		return out

	static func _random_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var cells: Array[Vector2i] = []
		for r in rows:
			for c in cols:
				cells.append(Vector2i(c, r))
		var out: Array[Vector2i] = []
		var pool := cells.duplicate()
		for i in count:
			if pool.is_empty():
				break
			var j := rng.randi_range(0, pool.size() - 1)
			out.append(pool[j])
			pool.remove_at(j)
		return out

	static func _ok(mines: Array[Vector2i], cols: int, rows: int) -> bool:
		var ms := {}
		for m in mines:
			ms[m] = true
		for r in rows - 1:
			for c in cols - 1:
				var n := 0
				for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
					if ms.has(Vector2i(c + d.x, r + d.y)):
						n += 1
				if n > 2:
					return false
		return true


func on_load() -> bool:
	RuleRegistry.default().register(LocalForbiddenRule.new())

	return true