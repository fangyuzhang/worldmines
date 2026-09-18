# entry.gd —— 遗留单算子包（8 个旧变体，默认不加载）
#
# 背景（2026-09-18）：对照《GDD 终版》§4 的三轴 22 席清理变体池。下面 8 个算子不在终版
# 范围内（各自的原因见每个 class 的注释），从 `core/rule_registry.gd` 的内置表移出，
# 收进本 Mod 作为**备用内容**：
#   · 列入 `ModAPI.BUNDLED_SKIP` → 启动**不自举**，不占选关页版面，也不进任何组合轴
#     （组合轴是 `VariantCatalog.OBS_IDS / STRUCT_IDS / CONSERVE_IDS` 三个静态常量）；
#   · 玩家想要就自己在主菜单「模组」页加载本 Mod，加载后它们作为**普通 Mod 变体**
#     出现在「Mod」页（`is_bundled_rule` 认为它们不是随包算子）。
#
# 为什么这样做而不是直接删：H1/H3 只要求"零导入、自定义命名"，没要求删历史实现；
# 而它们是规则平台原语的可用示例（`wsum` / 双值 `Array` 线索 / 分区守恒 / 构造式布雷），
# 留着比删掉更有用。**但绝不能放回内置表**——那会让选关页再次出现终版之外的变体。
#
# 逐项移出原因：
#   4n 四邻      : O0 经典的信息子集（4 正交 + 4 对角 = 8 邻），比经典更简单，无独立价值
#   sc 同色      : 对角 4 邻计数，与经典正交但被 O 轴十席完全覆盖
#   knight 骑士  : 非局部邻域，机制新鲜；但 H4 原创性存疑（市面同类作品常见），不入终版
#   fr 首雷      : 与 O9 射距重叠（射距是四向射线取最小，首雷只是单向向右）
#   distsum 曼哈顿和: 加权计数，与经典 / O6 热度部分重叠
#   hv 纵横分计  : 同格双数字 —— **违反 GDD §5.1 硬限制 5「同格双线索（E 类）禁用」**
#   ep 端点平衡  : 被 Z1 镜像逻辑蕴含（R4 判冗余），同关时零信息增量
#   4c 四向守恒  : 与 Z3 四象同属「分区计数平衡」，被 Z 轴五席覆盖
extends RefCounted


## 四邻：数字 = 正交 4 格雷数。
class N4Rule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"4n"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "四邻", "rule_text": "数字 = 上下左右 4 格雷数"}

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return RulePlugin.count_dirs(mine_set, pos, grid_size, ClueEngine.orthogonal_dirs())

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var nbs := b.neighbors(pos, ClueEngine.orthogonal_dirs())
		b.add_eq(b.sum(b.cell_vars(nbs)), int(value))

	func supports_mask() -> bool:
		return true

	func build_interval_constraints(b: RuleBuilder, pos: Vector2i, lo: int, hi: int) -> void:
		var nbs := b.neighbors(pos, ClueEngine.orthogonal_dirs())
		b.add_le(lo, b.sum(b.cell_vars(nbs)))
		b.add_le(b.sum(b.cell_vars(nbs)), hi)

	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		if value != 0:
			return []
		return RulePlugin.dirs_to_neighbors(pos, grid_size, ClueEngine.orthogonal_dirs())


## 同色：数字 = 对角 4 格雷数。
class SCRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"sc"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "同色", "rule_text": "数字 = 对角 4 格雷数"}

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return RulePlugin.count_dirs(mine_set, pos, grid_size, ClueEngine.diagonal_dirs())

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var nbs := b.neighbors(pos, ClueEngine.diagonal_dirs())
		b.add_eq(b.sum(b.cell_vars(nbs)), int(value))

	func supports_mask() -> bool:
		return true

	func build_interval_constraints(b: RuleBuilder, pos: Vector2i, lo: int, hi: int) -> void:
		var nbs := b.neighbors(pos, ClueEngine.diagonal_dirs())
		b.add_le(lo, b.sum(b.cell_vars(nbs)))
		b.add_le(b.sum(b.cell_vars(nbs)), hi)

	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		if value != 0:
			return []
		return RulePlugin.dirs_to_neighbors(pos, grid_size, ClueEngine.diagonal_dirs())


## 骑士：数字 = 骑士走位 8 格雷数（旧 Def 窗口原子无法表达——自举性实证）。
class KnightRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"knight"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "骑士", "rule_text": "数字 = 骑士走位 8 格雷数（任意窗口皆可自定义）"}

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return RulePlugin.count_dirs(mine_set, pos, grid_size, RuleRegistry.KNIGHT_DIRS)

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var nbs := b.neighbors(pos, RuleRegistry.KNIGHT_DIRS)
		b.add_eq(b.sum(b.cell_vars(nbs)), int(value))

	## 值 0 ⟹ 骑士步邻域无雷（扩散必须走骑士邻，否则会翻到不安全格）。
	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		if value != 0:
			return []
		return RulePlugin.dirs_to_neighbors(pos, grid_size, RuleRegistry.KNIGHT_DIRS)


## 首雷：数字 = 向右第一个雷的距离（格数），无雷 = "inf"。FR 永不扩散（值 0 = 右邻必雷）。
class FrRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"fr"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "首雷", "rule_text": "数字 = 向右第一颗雷的距离，无雷 = inf"}

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return ClueEngine._fr_value(mine_set, pos, grid_size)

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		if value is String and value == "inf":
			for c in range(pos.x + 1, b.cols):
				b.add_eq(b.cell_var(pos.y, c), 0)
			return
		var d := int(value)
		# 向右第 1..d 格非雷，第 d+1 格是雷
		for c in range(pos.x + 1, b.cols):
			var dist := c - pos.x
			if dist <= d:
				b.add_eq(b.cell_var(pos.y, c), 0)
			elif dist == d + 1:
				b.add_eq(b.cell_var(pos.y, c), 1)

	func zero_safe_neighbors(_pos: Vector2i, _grid_size: Vector2i, _value: Variant = null) -> Array[Vector2i]:
		return []  # FR 永不扩散（值 0 表示右邻必雷）


## 曼哈顿和：数字 = 正交×1 + 对角×2。wsum 原语直接表达。
class DistSumRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"distsum"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "曼哈顿和", "rule_text": "数字 = 邻域雷的曼哈顿距离加权和（正交 1 + 对角 2）"}

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return ClueEngine.compute(ClueEngine.Variant.DIST_SUM, mine_set, pos, grid_size)

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var vars := _dist_vars(b, pos)
		b.add_eq(b.wsum(_dist_weights(), vars), int(value))

	func supports_mask() -> bool:
		return true

	func value_upper_bound(_grid_size: Vector2i) -> int:
		return 12

	func build_interval_constraints(b: RuleBuilder, pos: Vector2i, lo: int, hi: int) -> void:
		var vars := _dist_vars(b, pos)
		var w := _dist_weights()
		b.add_le(lo, b.wsum(w, vars))
		b.add_le(b.wsum(w, vars), hi)

	static func _dist_weights() -> Array:
		return ClueEngine.dist_sum_dirs_weights()[1]

	static func _dist_vars(b: RuleBuilder, pos: Vector2i) -> Array:
		var dw: Array = ClueEngine.dist_sum_dirs_weights()
		var dirs: Array = dw[0]
		var vars: Array = []
		for d in dirs:
			var p: Vector2i = pos + d
			if b.in_board(p.y, p.x):
				vars.append(b.cell_var(p.y, p.x))
			else:
				vars.append(CPIR.const_expr(0))
		return vars

	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		if value != 0:
			return []
		return RulePlugin.dirs_to_neighbors(pos, grid_size, ClueEngine.ring_dirs())


## 纵横分计：每格双值 [正交雷数, 对角雷数]。两条约束 + 分分量扩散。
class HVRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"hv"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "纵横分计", "rule_text": "每格显示两个数字：正交雷数 + 对角雷数"}

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return ClueEngine.compute(ClueEngine.Variant.HV, mine_set, pos, grid_size)

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		if not (value is Array):
			return
		var ov := b.neighbors(pos, ClueEngine.orthogonal_dirs())
		var dv := b.neighbors(pos, ClueEngine.diagonal_dirs())
		b.add_eq(b.sum(b.cell_vars(ov)), int(value[0]))
		b.add_eq(b.sum(b.cell_vars(dv)), int(value[1]))

	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		if not (value is Array):
			return out
		if int(value[0]) == 0:
			for p in RulePlugin.dirs_to_neighbors(pos, grid_size, ClueEngine.orthogonal_dirs()):
				if not out.has(p):
					out.append(p)
		if int(value[1]) == 0:
			for p in RulePlugin.dirs_to_neighbors(pos, grid_size, ClueEngine.diagonal_dirs()):
				if not out.has(p):
					out.append(p)
		return out


## 端点平衡：最左列雷数 = 最右列雷数。
class EpRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"ep"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {"name": "端点平衡", "rule_text": "最左列与最右列雷数相等"}

	func build_global_constraints(b: RuleBuilder) -> void:
		if b.cols <= 1:
			return
		var left: Array = []
		var right: Array = []
		for r in b.rows:
			left.append(b.cell_var(r, 0))
			right.append(b.cell_var(r, b.cols - 1))
		b.add_eq(b.sum(left), b.sum(right))

	## 构造式布雷：最左/最右列各 k 雷 + 中间随机补齐。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if cols <= 1:
			return []
		for k in range(rows + 1):
			if 2 * k > count:
				break
			var middle: Array[Vector2i] = []
			for r in rows:
				for c in range(1, cols - 1):
					middle.append(Vector2i(c, r))
			var remaining := count - 2 * k
			if remaining <= middle.size():
				var mines := {}
				for r in RuleRegistry._sample_cells(rng, _col_cells(0, rows), k):
					mines[r] = true
				for r in RuleRegistry._sample_cells(rng, _col_cells(cols - 1, rows), k):
					mines[r] = true
				for m in RuleRegistry._sample_cells(rng, middle, remaining):
					mines[m] = true
				var out: Array[Vector2i] = []
				for m in mines:
					out.append(m)
				return out
		return []

	static func _col_cells(col: int, rows: int) -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		for r in rows:
			out.append(Vector2i(col, r))
		return out


## 四色：黑格（(r+c)偶）雷数 = 白格（(r+c)奇）雷数。构造式布雷保证总雷为偶数。
class FourColorRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"4c"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {"name": "四向守恒", "rule_text": "黑格雷数 = 白格雷数"}

	func build_global_constraints(b: RuleBuilder) -> void:
		var black: Array = []
		var white: Array = []
		for r in b.rows:
			for c in b.cols:
				if (c + r) % 2 == 0:
					black.append(b.cell_var(r, c))
				else:
					white.append(b.cell_var(r, c))
		b.add_eq(b.sum(black), b.sum(white))

	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if count % 2 != 0:
			return []
		var k := count / 2
		var black: Array[Vector2i] = []
		var white: Array[Vector2i] = []
		for r in rows:
			for c in cols:
				if (c + r) % 2 == 0:
					black.append(Vector2i(c, r))
				else:
					white.append(Vector2i(c, r))
		if black.size() < k or white.size() < k:
			return []
		var mines := {}
		for m in _sample(rng, black, k):
			mines[m] = true
		for m in _sample(rng, white, k):
			mines[m] = true
		var out: Array[Vector2i] = []
		for m in mines:
			out.append(m)
		return out

	static func _sample(rng: RandomNumberGenerator, cells: Array, k: int) -> Array:
		if k <= 0 or k > cells.size():
			return []
		var pool := cells.duplicate()
		var out: Array = []
		for _i in k:
			var j := rng.randi_range(0, pool.size() - 1)
			out.append(pool[j])
			pool.remove_at(j)
		return out


## 注册全部 8 个遗留算子。加载即出现在「模组」页，卸载即消失（mod_api 按 diff 反向清理）。
func on_load() -> bool:
	var reg := RuleRegistry.default()
	var ok := true
	for r in [N4Rule.new(), SCRule.new(), KnightRule.new(), FrRule.new(),
			DistSumRule.new(), HVRule.new(), EpRule.new(), FourColorRule.new()]:
		ok = reg.register(r) and ok
	return ok
