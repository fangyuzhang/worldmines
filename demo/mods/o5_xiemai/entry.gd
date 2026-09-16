# entry.gd —— O5 替换候选「斜脉」（隐藏斜向二选一 + 全盘配额；k 公开 = 难度旋钮）
#
# 演化（2026-09-14）：
#   v1「明版对角线求和」实测难度 0.03~0.08——纯计数型天花板（与 O5 同因，长线求和直推易）；
#   v2 按「高难基因（比较/隐藏/剥夺——O2/O4/O7 全部 0.5+）」规律升级为隐藏斜向：
#   · 每格隐藏一个「斜向选择」s_p ∈ {主斜（↘, r−c）, 副斜（↙, r+c)}——两条对角线均过本格；
#   · 数字 = 所选斜线（去心）上的雷总数；看哪条不显示；
#   · 全盘 s=1（副斜）的格数固定为 k（公开;k = 格数/4;后续可做「噩梦档 k 不公开」旋钮）。
#
# 不冲突论证（对 22 席全量）：
#   · vs O1 对穿（四轴两端合取 0–4）/O9 射距（正交射线首雷距离）/O5 三角（2×2 窗口饱和）：
#     信息类型全不同（求和/合取/饱和）；
#   · vs O4 变径（隐藏半径二选一）：同为「隐藏二选一 + 配额」手法，但载体与信息结构不同——
#     O4 隐藏「邻域宽度」（同心嵌套窗口 8↔24 格、候选相含）；
#     本算子隐藏「投影方向」（交叉的两条对角线、互不相含、跨格长程）。
#
# 编码：s 共享池（bool_var_at）+ u = s·(ΣB−ΣA) 的 McCormick 四线（全平铺）+
#   f = ΣA + u（平铺） + Σs = k（全局钩子）。零值不扩散（方向未知,无法确定哪条线安全）。
# 预检工具注意：本算子有隐藏态（同 O4/O5b），预检「序贯」项会假阴性——以 probe 为准。
extends RefCounted


class XiemaiRule:
	extends RulePlugin

	## s=1（选副斜线）的格集合（place_mines 时决定）。
	var _s1: Dictionary = {}

	func get_rule_id() -> StringName:
		return &"o5x"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "斜脉",
			"rule_text": "数字 = 穿过它的斜线（左上到右下、右上到左下 两条里随机一条，看哪条不显示）上除它以外的格子里雷的总数；全盘看右上到左下的格数固定",
		}

	## 主斜线（↘, r−c 常数）的全部格（含本格）。
	func _main_cells(pos: Vector2i, grid_size: Vector2i) -> Array[Vector2i]:
		var d := pos.y - pos.x
		var c_lo := maxi(0, -d)
		var c_hi := mini(grid_size.x - 1, grid_size.y - 1 - d)
		var out: Array[Vector2i] = []
		for c in range(c_lo, c_hi + 1):
			out.append(Vector2i(c, c + d))
		return out

	## 副斜线（↙, r+c 常数）的全部格（含本格）。
	func _anti_cells(pos: Vector2i, grid_size: Vector2i) -> Array[Vector2i]:
		var e := pos.y + pos.x
		var c_lo := maxi(0, e - (grid_size.y - 1))
		var c_hi := mini(grid_size.x - 1, e)
		var out: Array[Vector2i] = []
		for c in range(c_lo, c_hi + 1):
			out.append(Vector2i(c, e - c))
		return out

	func applies_to(pos: Vector2i, grid_size: Vector2i) -> bool:
		# 恒真：每格至少一条斜线去心 ≥1（角格如 (0,0) 的主斜线仍贯穿全盘；
		# 仅当 s=1 指向短副线时该格 f 恒 0——无损且 0 不扩散）。
		return _main_cells(pos, grid_size).size() >= 2 or _anti_cells(pos, grid_size).size() >= 2

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		var line := _anti_cells(pos, grid_size) if _s1.has(pos) else _main_cells(pos, grid_size)
		var count := 0
		for q in line:
			if q != pos and mine_set.has(q):
				count += 1
		return count

	func value_upper_bound(grid_size: Vector2i) -> int:
		return maxi(grid_size.x, grid_size.y) - 1

	# ==== k 旋钮（2026-09-16 实装：与 o4 同款；原注释「k 公开 = 难度旋钮」的兑现）====
	# k_ratio：配额比例（默认 0.25 ≈ 格数/4，向后兼容）；k_public=false 时编码省略 Σs=k
	#（「不知 k」演绎口径：生成验证即在无配额信息下进行，通过 = 满足 R01 可不公开交付）。
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

	## 便捷重置（契约防护）：规则为注册表单例——调用方 set 后应在生成结束（或批次结束）调用本方法，
	## 避免状态跨调用残留（同 _s1 的状态管理契约）。
	func reset_k_knob() -> void:
		_k_ratio = 0.25
		_k_public = true

	# ==== 逆向编码 ====

	static func _sid(c: int, r: int) -> int:
		return 1_000_000 + r * 64 + c

	func build_global_clue_constraints(b: RuleBuilder) -> void:
		var ss: Array = []
		for rr in b.rows:
			for cc in b.cols:
				ss.append(b.bool_var_at(_sid(cc, rr)))
		# k_public=false（「不公开」）：省略 Σs=k——「不知 k」演绎口径（保 R01 验证）。
		if _k_public:
			b.add_eq(b.sum(ss), _k_of(b.cols, b.rows))

	static func _ones(n: int) -> Array:
		var out: Array = []
		for _i in n:
			out.append(1)
		return out

	static func _neg_ones(n: int) -> Array:
		var out: Array = []
		for _i in n:
			out.append(-1)
		return out

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var s := b.bool_var_at(_sid(pos.x, pos.y))
		var gs := Vector2i(b.cols, b.rows)
		var a_cells: Array = []
		for q in _main_cells(pos, gs):
			if q != pos:
				a_cells.append(b.cell_var(q.y, q.x))
		var b_cells: Array = []
		for q in _anti_cells(pos, gs):
			if q != pos:
				b_cells.append(b.cell_var(q.y, q.x))
		var na := a_cells.size()
		var nbb := b_cells.size()
		var ml := -na          # X = ΣB − ΣA 的下界
		var mu := nbb          # 上界
		var u := b.int_var(ml, maxi(mu, 0))
		# u = s·X 的 McCormick 四线（全平铺）
		b.add_le(u, b.lin([mu], [s]))                                       # u ≤ mu·s
		b.add_le(b.lin([ml], [s]), u)                                       # ml·s ≤ u
		b.add_le(u, b.lin(_ones(nbb) + _neg_ones(na) + [ml], b_cells + a_cells + [s], -ml))
		b.add_le(b.lin(_ones(nbb) + _neg_ones(na) + [mu], b_cells + a_cells + [s], -mu), u)
		# f = ΣA + u（平铺）
		b.add_eq(b.lin(_ones(na) + [1], a_cells + [u]), int(value))

	# ==== 构造式布雷 + s 配额分配 ====

	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		_s1.clear()
		var all_cells: Array = []
		for r in rows:
			for c in cols:
				all_cells.append(Vector2i(c, r))
		var k := _k_of(cols, rows)
		for _i in range(mini(k, all_cells.size())):
			var pi := rng.randi_range(0, all_cells.size() - 1)
			_s1[all_cells[pi]] = true
			all_cells.remove_at(pi)
		# 效率布雷（同 O1/O5：低聚类 + 偏边缘加权序列采样）
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
			for d in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(-1, 1)]:
				var q: Vector2i = chosen + d
				if weights.has(q):
					weights[q] = maxf(0.05, float(weights[q]) * 0.35)
		return out

	# ==== 隐藏态导出/导入（载盘复现，2026-09-16；坐标格式与 mines/revealed 一致）====

	func export_hidden_state() -> Dictionary:
		var arr: Array = []
		for p in _s1:
			arr.append({"c": p.x, "r": p.y})
		arr.sort_custom(RulePlugin.state_pos_less)
		return {"s1": arr}

	func import_hidden_state(state: Dictionary) -> void:
		_s1.clear()
		for it in state.get("s1", []):
			_s1[Vector2i(int(it["c"]), int(it["r"]))] = true


func on_load() -> void:
	RuleRegistry.default().register(XiemaiRule.new())
