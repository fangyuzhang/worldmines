# rule_registry.gd —— 规则注册表 + 内置规则（自举式平台，全部走公共 API）
# 关键设计：**dogfood（吃自己的狗粮）**——内置规则（classic/4n/sc/knight/
# mx/pf/total_mines）与第三方 mod 规则用同一套 RuleBuilder 原语实现。
# 平台自己能做到的，创作者都能做到；创作者需要的原语，平台内部也在用。
#
# 第三方接入（两种等价路径）：
#   1. 直接注册：entry.gd 的 on_load 里 RuleRegistry.default().register(MyRule.new())
#   2. ModAPI 扩展点：ModAPI.register_extension(&"rules", MyRule.new())
#      生成时 RuleRegistry.harvest(ModAPI.plugins) 收割（见 demo/mods/knight_rule_mod）
class_name RuleRegistry
extends RefCounted


## ModAPI 扩展点名（Mod 自举注册入口，与内置点共用 declare_point）。
const EXTENSION_POINT := &"rules"
## 扩展点契约（鸭子类型：RulePlugin 基类已全部提供默认实现）。
const CONTRACT := [
	"get_rule_id", "get_kind", "describe",
	"compute_clue", "build_clue_constraints", "build_global_constraints",
]

## 骑士走位 8 偏移（旧 Def IR 的窗口原子无法表达 → 自举性的实证）。
const KNIGHT_DIRS := [
	Vector2i(1, 2), Vector2i(2, 1), Vector2i(2, -1), Vector2i(1, -2),
	Vector2i(-1, -2), Vector2i(-2, -1), Vector2i(-2, 1), Vector2i(-1, 2),
]

# rule_id(StringName) -> RulePlugin
var _rules: Dictionary = {}
var _builtin_ids: Array[String] = []

static var _default: RuleRegistry = null


## 全局共享注册表（内置规则随首建注册；mod 注册也进这里）。
static func default() -> RuleRegistry:
	if _default == null:
		_default = RuleRegistry.new()
	return _default


func _init() -> void:
	_register_builtins()


## 注册规则（鸭子类型校验）。返回是否成功。
func register(rule: Object) -> bool:
	if rule == null or not rule.has_method("get_rule_id"):
		return false
	var id := StringName(str(rule.call("get_rule_id")))
	if String(id) == "":
		return false
	_rules[id] = rule
	return true


## 注销规则（P0-T5：卸载 mod 时清理其注册的规则）。
## 内置规则不可注销——调用方（ModAPI）只对 mod 注册的规则调用本方法。
func unregister(rule_id: StringName) -> bool:
	return _rules.erase(rule_id)


func resolve(rule_id: StringName) -> Object:
	return _rules.get(rule_id)


## 批量解析；任一未知 → 空数组。
func resolve_all(ids: Array) -> Array:
	var out: Array = []
	for id in ids:
		var r := resolve(StringName(str(id)))
		if r == null:
			return []
		out.append(r)
	return out


func all_ids() -> Array:
	var out: Array = []
	for id in _rules:
		out.append(String(id))
	out.sort()
	return out


## 从 PluginManager（ModAPI.plugins）收割 mod 注册的规则。
func harvest(pm: Object) -> void:
	if pm == null or not pm.has_method("declare_point"):
		return
	pm.declare_point(EXTENSION_POINT, CONTRACT)
	if not pm.has_method("all"):
		return
	for impl in pm.all(EXTENSION_POINT):
		register(impl)


func _register_builtins() -> void:
	var rules: Array = [
		ClassicRule.new(), N4Rule.new(), SCRule.new(), KnightRule.new(),
		ClockRule.new(), FrRule.new(), LoopRunsRule.new(), DistSumRule.new(),
		HVRule.new(), MxRule.new(), PfRule.new(), RlRule.new(),
		QdRule.new(), EpRule.new(), FourColorRule.new(), DtRule.new(),
		TotalMinesRule.new(),
	]
	for r in rules:
		if register(r):
			_builtin_ids.append(String(r.get_rule_id()))


## 内置规则 id（与 mod 注册的规则区分）。
func builtin_ids() -> Array[String]:
	return _builtin_ids.duplicate()


## 非内置（mod/第三方注册）规则 id。
func custom_ids() -> Array[String]:
	var bi := {}
	for id in _builtin_ids:
		bi[id] = true
	var out: Array[String] = []
	for id in _rules:
		var sid := String(id)
		if not bi.has(sid):
			out.append(sid)
	out.sort()
	return out


## 共享：Fisher-Yates 采样 k 个不重复元素（构造式布雷共用）。
static func _sample_cells(rng: RandomNumberGenerator, cells: Array, k: int) -> Array:
	if k <= 0 or k > cells.size():
		return []
	var pool := cells.duplicate()
	var out: Array = []
	for _i in k:
		var j := rng.randi_range(0, pool.size() - 1)
		out.append(pool[j])
		pool.remove_at(j)
	return out


# ============ 内置规则（dogfood：与 mod 用同一套原语） ============

## 经典：数字 = 8 邻雷数。
class ClassicRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"classic"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "经典", "rule_text": "数字 = 周围 8 格雷数"}

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return RulePlugin.count_dirs(mine_set, pos, grid_size, ClueEngine.ring_dirs())

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var nbs := b.neighbors(pos, ClueEngine.ring_dirs())
		b.add_eq(b.sum(b.cell_vars(nbs)), int(value))

	func supports_mask() -> bool:
		return true

	func build_interval_constraints(b: RuleBuilder, pos: Vector2i, lo: int, hi: int) -> void:
		var nbs := b.neighbors(pos, ClueEngine.ring_dirs())
		b.add_le(lo, b.sum(b.cell_vars(nbs)))
		b.add_le(b.sum(b.cell_vars(nbs)), hi)

	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		if value != 0:
			return []
		return RulePlugin.dirs_to_neighbors(pos, grid_size, ClueEngine.ring_dirs())


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


## 镜像：左右对称（全局约束 + 构造式布雷）。
class MxRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"mx"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {"name": "镜像", "rule_text": "雷区左右镜像对称"}

	func build_global_constraints(b: RuleBuilder) -> void:
		for r in b.rows:
			for c in int(b.cols / 2):
				b.add_eq(b.cell_var(r, c), b.cell_var(r, b.cols - 1 - c))

	## 构造式布雷：左半区采样 + 镜像；奇数雷数需中轴列。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var has_axis := (cols % 2 == 1)
		var left: Array[Vector2i] = []
		var axis: Array[Vector2i] = []
		for r in rows:
			for c in int(cols / 2):
				left.append(Vector2i(c, r))
			if has_axis:
				axis.append(Vector2i(cols / 2, r))
		# 收集合法 (k, j)：2k + j = count
		var options: Array = []
		for j in range(axis.size() + 1):
			if j > count:
				break
			var rem := count - j
			if rem % 2 != 0:
				continue
			var k := rem / 2
			if k > left.size():
				continue
			options.append([k, j])
		if options.is_empty():
			return []
		var pick: Array = options[rng.randi_range(0, options.size() - 1)]
		var mines := {}
		for m in _sample(rng, left, pick[0]):
			mines[m] = true
			mines[Vector2i(cols - 1 - m.x, m.y)] = true
		for m in _sample(rng, axis, pick[1]):
			mines[m] = true
		var out: Array[Vector2i] = []
		for m in mines:
			out.append(m)
		return out

	static func _sample(rng: RandomNumberGenerator, cells: Array, k: int) -> Array:
		if k <= 0 or k > cells.size():
			return []
		var idx: Array[int] = []
		for i in cells.size():
			idx.append(i)
		for i in range(idx.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var t := idx[i]
			idx[i] = idx[j]
			idx[j] = t
		var out: Array = []
		for i in k:
			out.append(cells[idx[i]])
		return out


## 禁形：任意 2×2 至多 2 雷。
class PfRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"pf"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {"name": "禁形", "rule_text": "任意 2×2 方块至多 2 雷"}

	func build_global_constraints(b: RuleBuilder) -> void:
		for r in b.rows - 1:
			for c in b.cols - 1:
				var quad := [
					b.cell_var(r, c), b.cell_var(r, c + 1),
					b.cell_var(r + 1, c), b.cell_var(r + 1, c + 1),
				]
				b.add_le(b.sum(quad), 2)

	## 随机 + 过滤布雷。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		for _attempt in 300:
			var mines := _random_mines(rng, cols, rows, count)
			if _ok(mines, cols, rows):
				return mines
		return []

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


## 总雷数：全盘雷数 = N（读 builder.total_mines）。
class TotalMinesRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"total_mines"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {"name": "总雷数", "rule_text": "全盘雷数等于给定值"}

	func build_global_constraints(b: RuleBuilder) -> void:
		if b.total_mines < 0:
			return
		var all: Array = []
		for r in b.rows:
			for c in b.cols:
				all.append(b.cell_var(r, c))
		b.add_eq(b.sum(all), b.total_mines)


## 钟点：数字 = 8 邻顺时针首个雷方位（1~8），无雷 = 0。非计数型，用条件约束表达。
class ClockRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"clock"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "钟点", "rule_text": "数字 = 顺时针第一颗雷的方位（1~8），无雷 = 0"}

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return ClueEngine._clock_value(mine_set, pos, grid_size)

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var dirs := ClueEngine.ring_dirs()
		var v := int(value)
		if v == 0:
			var all: Array = []
			for d in dirs:
				var p: Vector2i = pos + d
				if b.in_board(p.y, p.x):
					all.append(b.cell_var(p.y, p.x))
			b.add_eq(b.sum(all), 0)
			return
		# v = 1..8：方位编号固定（dirs 索引），dirs[v-1] 是雷、dirs[0..v-2] 非雷
		for i in dirs.size():
			var p: Vector2i = pos + dirs[i]
			if not b.in_board(p.y, p.x):
				continue
			if i < v - 1:
				b.add_eq(b.cell_var(p.y, p.x), 0)
			elif i == v - 1:
				b.add_eq(b.cell_var(p.y, p.x), 1)

	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		if value != 0:
			return []
		return RulePlugin.dirs_to_neighbors(pos, grid_size, ClueEngine.ring_dirs())


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


## 环游程：数字 = 8 邻环序连续雷段数。用 aux 布尔表达「段起点」，考验 enforce/imp/iff 原语。
class LoopRunsRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"loopruns"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "环游程", "rule_text": "数字 = 周围连续雷段数（环序首尾相接）"}

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
		b.add_eq(b.sum(runs), int(value))

	func zero_safe_neighbors(pos: Vector2i, grid_size: Vector2i, value: Variant = null) -> Array[Vector2i]:
		if value != 0:
			return []
		return RulePlugin.dirs_to_neighbors(pos, grid_size, ClueEngine.ring_dirs())


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


## 相邻行锁：相邻两行雷数差 = 1。用 lin 原语 + aux 开关表达 |diff|==1。
class RlRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"rl"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {"name": "相邻行锁", "rule_text": "相邻两行的雷数差为 1"}

	func build_global_constraints(b: RuleBuilder) -> void:
		for r in b.rows - 1:
			var a_vars := _row_vars(b, r)
			var b_vars := _row_vars(b, r + 1)
			var ones: Array = []
			for _i in a_vars.size():
				ones.append(1)
			var d := b.bool_var()
			# d 真 → sum(a) == sum(b)+1；d 假 → sum(a) == sum(b)-1
			b.add_eq(b.lin(ones, a_vars, 0), b.lin(ones, b_vars, 1), [d])
			b.add_eq(b.lin(ones, a_vars, 0), b.lin(ones, b_vars, -1), [b.not_lit(d)])

	static func _row_vars(b: RuleBuilder, r: int) -> Array:
		var out: Array = []
		for c in b.cols:
			out.append(b.cell_var(r, c))
		return out

	## 构造式布雷：DFS 构造行雷数序列（每步 ±1，总和 = count），再逐行布雷。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		for _try in 50:
			var seq: Array[int] = []
			seq.resize(rows)
			if _rl_dfs(rng, seq, 0, cols, rows, count, 0):
				var mines := {}
				for r in rows:
					var row_cells: Array[Vector2i] = []
					for c in cols:
						row_cells.append(Vector2i(c, r))
					for m in RuleRegistry._sample_cells(rng, row_cells, seq[r]):
						mines[m] = true
				var out: Array[Vector2i] = []
				for m in mines:
					out.append(m)
				return out
		return []

	static func _rl_dfs(rng: RandomNumberGenerator, seq: Array[int], r: int, cols: int, rows: int, target: int, cur_sum: int) -> bool:
		if r == rows:
			return cur_sum == target
		var rem_rows := rows - r - 1
		var cands: Array[int] = []
		if r == 0:
			for v in range(cols + 1):
				cands.append(v)
		else:
			for d: int in [-1, 1]:
				var v: int = seq[r - 1] + d
				if v >= 0 and v <= cols:
					cands.append(v)
		for i in range(cands.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var t := cands[i]
			cands[i] = cands[j]
			cands[j] = t
		for v in cands:
			var rem_need: int = target - cur_sum - v
			if rem_need < 0 or rem_need > rem_rows * cols:
				continue
			seq[r] = v
			if _rl_dfs(rng, seq, r + 1, cols, rows, target, cur_sum + v):
				return true
		return false


## 四象限：去掉中央行/列后四象限雷数相等。
class QdRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"qd"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {"name": "四象", "rule_text": "四象限雷数相等（中央行列除外）"}

	func build_global_constraints(b: RuleBuilder) -> void:
		var q: Array = [[], [], [], []]
		for r in b.rows:
			for c in b.cols:
				var qi := ConstraintEngine.quadrant_of(r, c, b.rows, b.cols)
				if qi >= 0:
					q[qi].append(b.cell_var(r, c))
		b.add_eq(b.sum(q[0]), b.sum(q[1]))
		b.add_eq(b.sum(q[1]), b.sum(q[2]))
		b.add_eq(b.sum(q[2]), b.sum(q[3]))

	## 构造式布雷：四象限各 k 雷 + 中央行列随机补齐。
	## 全偶盘（无中轴）雷数须为 4 的倍数，否则调平（对齐 FourColorRule 的偶数调平精神）。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var q: Array = [[], [], [], []]
		var cross: Array[Vector2i] = []
		for r in rows:
			for c in cols:
				var qi := ConstraintEngine.quadrant_of(r, c, rows, cols)
				if qi < 0:
					cross.append(Vector2i(c, r))
				else:
					q[qi].append(Vector2i(c, r))
		if (rows % 2 == 0) and (cols % 2 == 0):
			count -= count % 4
			if count <= 0:
				return []
		var q_max: int = mini(mini(q[0].size(), q[1].size()), mini(q[2].size(), q[3].size()))
		# 收集「全部」合法 k 再随机取一个（与 G1 镜像 _place_mx 同策略）。
		# 历史 bug：取第一个可行 k（恒为最小值）→ 雷几乎全堆在中央十字/中轴，
		# 四象限空空如也，关卡多样性极差（不同种子长得几乎一样）。
		var options: Array = []
		for k in range(q_max + 1):
			if 4 * k > count:
				break
			var remaining := count - 4 * k
			if remaining <= cross.size():
				options.append(k)
		if options.is_empty():
			return []
		var kk: int = options[rng.randi_range(0, options.size() - 1)]
		var rest: int = count - 4 * kk
		var mines := {}
		for i in range(4):
			for m in RuleRegistry._sample_cells(rng, q[i], kk):
				mines[m] = true
		for m in RuleRegistry._sample_cells(rng, cross, rest):
			mines[m] = true
		var out: Array[Vector2i] = []
		for m in mines:
			out.append(m)
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


## 骨牌边界：棋盘划分为 2×1 骨牌，每骨牌恰 1 雷。骨牌划分由本规则 place_mines 生成并持有。
class DtRule:
	extends RulePlugin

	var _dominoes: Array = []

	func get_rule_id() -> StringName:
		return &"dt"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {"name": "骨牌边界", "rule_text": "每块 2×1 骨牌恰 1 雷"}

	## 底座化：骨牌划分（采样骨牌）的读写。
	## 生成时由 place_mines 设置；加载关卡时由 Board 把 JSON 的 dominoes 字段同步进来，
	## 保证约束构建（build_global_constraints）用「当前关卡」的划分而非上次生成的。
	func get_dominoes() -> Array:
		return _dominoes

	func set_dominoes(d: Array) -> void:
		_dominoes = d

	func build_global_constraints(b: RuleBuilder) -> void:
		for d in _dominoes:
			var cells: Array = []
			for p in d:
				cells.append(b.cell_var(p.y, p.x))
			b.add_eq(b.sum(cells), 1)

	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var cells: Array[Vector2i] = []
		for r in rows:
			for c in cols:
				cells.append(Vector2i(c, r))
		var used := {}
		var dominoes: Array = []
		for r in rows:
			for c in cols:
				var a := Vector2i(c, r)
				if used.has(a):
					continue
				var b := Vector2i(c + 1, r)
				if c + 1 < cols and not used.has(b):
					used[a] = true
					used[b] = true
					dominoes.append([a, b])
				else:
					var bv := Vector2i(c, r + 1)
					if r + 1 < rows and not used.has(bv):
						used[a] = true
						used[bv] = true
						dominoes.append([a, bv])
					else:
						used[a] = true
		if dominoes.size() < count:
			return []
		_dominoes = _sample_dominoes(rng, dominoes, count)
		var mines: Array[Vector2i] = []
		for d in _dominoes:
			mines.append(d[rng.randi_range(0, 1)])
		return mines

	static func _sample_dominoes(rng: RandomNumberGenerator, dominoes: Array, k: int) -> Array:
		var idx: Array[int] = []
		for i in dominoes.size():
			idx.append(i)
		for i in range(idx.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var t := idx[i]
			idx[i] = idx[j]
			idx[j] = t
		var out: Array = []
		for i in k:
			out.append(dominoes[idx[i]])
		return out
