# entry.gd —— O10「环游」（观测轴；环序连续雷段数）
#
# 语义（GDD §4.2 O10）：八邻域中盘内的格按方位编号表排成环序（首尾相接，越界跳过）。
# 数字 = 环上连续雷段的段数：空环 0、**全环 1**（视作一整段）、其余为「非雷→雷」跳变次数。
# 值域：内部 0–4，非角边 0–2，角 0–1。零值扩散：八邻域（可扩散族）。
#
# 编码：runs[i] ⟺ cur_i ∧ ¬prev_i（imp/or 原语钉死），按值分支——
#   值 0 ⟺ 空环（Σruns==0 且至少一格非雷）；值 1 ⟺ 恰一段 或 全雷环（段起点两两互斥 + 至少一格雷）；
#   值 ≥2 ⟺ Σruns == value。与内置 loopruns（C 类变体）同语义（零值修复版），
#   本 mod 为观测轴 O10 的规则平台化形态（probe/预检/GUT 全链路按 O 系标准执行）。
extends RefCounted


class HuanyouRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"o10"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "环游",
			"rule_text": "数字 = 周围一圈的雷被断成了几截（环序首尾相接）；连成一圈的算 1，一圈没有雷是 0",
		}

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return ClueEngine._loop_runs_value(mine_set, pos, grid_size)

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var cells: Array = []
		for d in ClueEngine.ring_dirs():
			var p: Vector2i = pos + d
			if b.in_board(p.y, p.x):
				cells.append(b.cell_var(p.y, p.x))
		if cells.is_empty():
			return
		var n := cells.size()
		var runs: Array = []
		for i in n:
			var ri := b.bool_var()
			runs.append(ri)
			var cur: Dictionary = cells[i]
			var prev: Dictionary = cells[(i - 1 + n) % n]
			b.add_imp(ri, cur)                            # ri → cur==1
			b.add_imp(ri, b.not_lit(prev))                # ri → prev==0
			b.add_bool_or([b.not_lit(cur), prev, ri])     # (cur==1 ∧ prev==0) → ri
		# runs[i] ⟺ cur_i ∧ ¬prev_i 已钉死，Σruns 由格状态唯一决定；按值分支编码（全雷环=1）。
		var v := int(value)
		if v == 0:
			b.add_eq(b.sum(runs), 0)
			var not_mine: Array = []
			for c in cells:
				not_mine.append(b.not_lit(c))
			b.add_bool_or(not_mine)
		elif v == 1:
			for i in runs.size():
				for j in range(i + 1, runs.size()):
					b.add_bool_or([b.not_lit(runs[i]), b.not_lit(runs[j])])
			b.add_bool_or(cells.duplicate())
		else:
			b.add_eq(b.sum(runs), v)

	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		if value == null or int(value) != 0:
			return []
		return dirs_to_neighbors(pos, grid_size, ClueEngine.ring_dirs())

	func value_upper_bound(_grid_size: Vector2i) -> int:
		return 4  # 内部最多 4 段（GDD：值域 0–4）


func on_load() -> bool:
	RuleRegistry.default().register(HuanyouRule.new())

	return true