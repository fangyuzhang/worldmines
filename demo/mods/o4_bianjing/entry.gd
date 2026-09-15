# entry.gd —— O4「变径」（v3.0 GDD §4.2 O4 / §4.3）
#
# 规则：每格带隐藏半径 r_p∈{1,2}；数字 = 切比雪夫距离 ≤ r_p（去心）范围内雷数。
# 全盘取半径 2 的格数固定为 k（公开；本实现 k = 格数/4，整数）。5×5 不生产（半径 2 覆盖全盘退化）。
# 值域 0–24。零值语义：可扩散（保守至八邻域——两种半径下均无雷 → 半径 1 邻域必安全，GDD §4.3）。
# 遮蔽：不启用。构造式布雷：效率布雷（与 O1 同方案）。
#
# 求解器编码（GDD §4.3）：
#   w_p 布尔 = [r_p=2]；u_p = w_p · D_p 线性化：
#     u ≤ 24·w、u ≤ D、u ≥ D − 24(1−w)
#   f_p = A_p + u_p；∑_p w_p = k
#   实现要点：w/u 用 builder.scratch 按格缓存（同一批变量被本格与邻格的约束共享）；
#   全局配额 ∑w=k 在「首个线索格的 build」触发（遍历全盘创建 w 后一次 add_eq）——逐格钩子内的全局约束。
#
# 状态管理：r 分配在 place_mines 用 rng 决定（存实例 _r2），compute_clue 读取。
# 落盘 schema 扩展（radius2 字段）与 Board 渲染接线是后续里程碑任务（本次先过生成+预检+测试闭环）。
#
# 本算子为 v3.0 换血第七个（S3 里程碑；GDD §8.2 可行性表：5×5 停用，6-9 需限 k）。
extends RefCounted


class VariRadiusRule:
	extends RulePlugin

	const NB8 := [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	]

	## 切比雪夫环 2（16 格）= N2 \ N1。
	const N2_OUT := [
		Vector2i(-2, -2), Vector2i(-1, -2), Vector2i(0, -2), Vector2i(1, -2), Vector2i(2, -2),
		Vector2i(2, -1), Vector2i(2, 0), Vector2i(2, 1),
		Vector2i(2, 2), Vector2i(1, 2), Vector2i(0, 2), Vector2i(-1, 2), Vector2i(-2, 2),
		Vector2i(-2, 1), Vector2i(-2, 0), Vector2i(-2, -1),
	]

	## r=2 分配集合（place_mines 时决定；本盘会话内有效）。
	var _r2: Dictionary = {}

	func get_rule_id() -> StringName:
		return &"o4"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "变径",
			"rule_text": "每个数字统计的范围不一样：有的只统计周围一圈，有的统计到外面第二圈，属于哪一种不显示（全盘取第二圈的格数固定为 k）",
		}

	func applies_to(_pos: Vector2i, grid_size: Vector2i) -> bool:
		# GDD §4.3 硬性判定：5×5 不生产（半径 2 覆盖全盘、数字恒等于总雷数）
		return grid_size.x > 5

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		var f := 0
		for d in NB8:
			var q: Vector2i = pos + d
			if q.x < 0 or q.x >= grid_size.x or q.y < 0 or q.y >= grid_size.y:
				continue
			if mine_set.has(q):
				f += 1
		if _r2.has(pos):
			for d in N2_OUT:
				var q2: Vector2i = pos + d
				if q2.x < 0 or q2.x >= grid_size.x or q2.y < 0 or q2.y >= grid_size.y:
					continue
				if mine_set.has(q2):
					f += 1
		return f

	# ==== k 旋钮（2026-09-16 实装：GDD §4.2「k 是否公开」+ 生成器把手）====
	# k_ratio：配额比例（默认 0.25 ≈ 格数/4，向后兼容）；GDD「k 越大可行域越窄」→ 可调控欠产率。
	# k_public：普通档公开 k（编码含 Σw=k，玩家可用配额收口推理）；噩梦档不公开——
	#   编码**省略 Σw=k**（「不知 k」演绎口径）：生成时的序贯验证即在「无配额信息」下进行，
	#   通过 = 该盘满足 R01（无 k 也可推完）→ 可不公开交付。调用方生成前 set_*（同 set_dominoes 先例）。
	var _k_ratio: float = 0.25
	var _k_public: bool = true

	func set_k_ratio(r: float) -> void:
		_k_ratio = clampf(r, 0.05, 0.5)

	func get_k_ratio() -> float:
		return _k_ratio

	func set_k_public(v: bool) -> void:
		_k_public = v

	func is_k_public() -> bool:
		return _k_public

	func _k_of(cols: int, rows: int) -> int:
		return maxi(1, int(floor(float(cols * rows) * _k_ratio)))

	## 共享变量池的索引公式（远离自动编号段的固定偏移——见 RuleBuilder.bool_var_at 注释）。
	static func _wid(c: int, r: int) -> int:
		return 1_000_000 + r * 64 + c

	## v3.0 全局钩子：全部格的 w 变量池 + 全盘配额 ∑w = k。
	## w_p 池以固定索引声明一次（此 builder 为首见创建者）；逐格 builder 用同索引引用同池
	##（C# 侧 aux 按索引池化 + build_spec 的 aux 去重保证「每索引一份」）。
	func build_global_clue_constraints(b: RuleBuilder) -> void:
		var ws: Array = []
		for rr in b.rows:
			for cc in b.cols:
				ws.append(b.bool_var_at(_wid(cc, rr)))
		# k_public=false（噩梦档「不公开」）：省略 Σw=k——「不知 k」演绎口径（保 R01 验证）。
		if _k_public:
			b.add_eq(b.sum(ws), _k_of(b.cols, b.rows))

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		# 引用共享池中的 w_p（同索引 = 同变量）
		var w := b.bool_var_at(_wid(pos.x, pos.y))
		# u_p = w_p · D_p（线性化；u 为局部辅助，无需共享）
		# 注意：C# 翻译器要求 wsum 的项为「叶子变量引用」——lin 的 xs 不能嵌 sum 表达式，
		# 故所有 lin 一律「平铺」到 cell/aux 叶子（O4 复盘的首个翻译坑）。
		var u := b.int_var(0, 24)
		var out_cells := b.cell_vars(b.neighbors(pos, N2_OUT))
		var n8_cells := b.cell_vars(b.neighbors(pos, NB8))
		b.add_le(u, b.lin([24], [w]))                     # u ≤ 24w
		b.add_le(u, b.sum(out_cells))                     # u ≤ D
		# D − 24(1−w) ≤ u  ⟺  −u + ΣD + 24w − 24 ≤ 0（平铺 lin）
		b.add_le(b.lin([-1] + _ones(out_cells.size()) + [24], [u] + out_cells + [w], -24), 0)
		# f = A + u  ⟺  ΣA + u = f（平铺 lin）
		b.add_eq(b.lin(_ones(n8_cells.size()) + [1], n8_cells + [u]), int(value))

	static func _ones(n: int) -> Array:
		var out: Array = []
		for _i in n:
			out.append(1)
		return out

	func value_upper_bound(_grid_size: Vector2i) -> int:
		return 24

	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		# f=0 → 两种半径下均无雷 → 八邻域安全（保守扩散，GDD §4.3）
		if value == null or int(value) != 0:
			return []
		return dirs_to_neighbors(pos, grid_size, NB8)

	## 效率布雷 + r=2 分配（一次成型）。k = _k_of（默认 = 格数/4）。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		# r=2 分配：从全部格中无放回抽 k 个
		_r2.clear()
		var all_cells: Array = []
		for r in rows:
			for c in cols:
				all_cells.append(Vector2i(c, r))
		var k := _k_of(cols, rows)
		for _i in range(mini(k, all_cells.size())):
			var pick_idx := rng.randi_range(0, all_cells.size() - 1)
			_r2[all_cells[pick_idx]] = true
			all_cells.remove_at(pick_idx)
		# 效率布雷（低聚类 + 偏边缘加权序列采样）
		var weights: Dictionary = {}
		for r in rows:
			for c in cols:
				var edge := c == 0 or r == 0 or c == cols - 1 or r == rows - 1
				weights[Vector2i(c, r)] = 1.25 if edge else 1.0
		var out: Array[Vector2i] = []
		for _i in count:
			var total := 0.0
			for p in weights:
				total += float(weights[p])
			if total <= 0.0:
				break
			var pick := rng.randf() * total
			var acc := 0.0
			var chosen := Vector2i(-1, -1)
			for p in weights:
				acc += float(weights[p])
				if acc >= pick:
					chosen = p
					break
			if chosen.x < 0:
				break
			out.append(chosen)
			weights.erase(chosen)
			for d in NB8:
				var q: Vector2i = chosen + d
				if weights.has(q):
					weights[q] = maxf(0.05, float(weights[q]) * 0.35)
		return out

	# ==== 隐藏态导出/导入（载盘复现，2026-09-16；「radius2 落盘」里程碑兑现——通用 hidden_state 机制）====

	func export_hidden_state() -> Dictionary:
		var arr: Array = []
		for p in _r2:
			arr.append({"c": p.x, "r": p.y})
		arr.sort_custom(RulePlugin.state_pos_less)
		return {"r2": arr}

	func import_hidden_state(state: Dictionary) -> void:
		_r2.clear()
		for it in state.get("r2", []):
			_r2[Vector2i(int(it["c"]), int(it["r"]))] = true


func on_load() -> void:
	RuleRegistry.default().register(VariRadiusRule.new())
