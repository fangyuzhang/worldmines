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
## 内置规则不可注销（v3.1/H3）：_builtin_ids 由 _register_builtins 登记，
## 调用方传错 id / mod diff 误判时拒绝并告警，防止内置表被静默掏空
## （内置规则失效会让 classic/mx/pf 等全部关卡「规则未注册」显式报错，
## 或更糟——走旧坑 #9 的静默降级路径）。
func unregister(rule_id: StringName) -> bool:
	if _builtin_ids.has(String(rule_id)):
		push_warning("RuleRegistry: 拒绝注销内置规则 %s" % String(rule_id))
		return false
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
	# 终版 GDD §4 的三轴 22 席**不在这里**：它们随 `demo/mods/` 自举加载（ModAPI.bootstrap_bundled_mods）。
	# 本表只留：
	#   · classic —— O0 底座；
	#   · clock / loopruns / pf / mx / rl / qd —— 与官方席位（o8/o10/s1/z1/z2/z3）等价的实现，
	#     选关页按 VariantCatalog.HIDDEN_RULES 隐藏（只显示官方 id），实现本身保留，
	#     供 RuleSignature / RuleFeasibility / 旧存档等按 id 直接引用；
	#   · dt —— 骨牌，唯一保留的旧单算子（只单独成关，不进任何组合轴）；
	#   · total_mines —— 元规则（不是玩法变体，选关页同样隐藏）。
	# 其余 8 个旧算子（4n/sc/knight/fr/distsum/hv/ep/4c）已移入 demo/mods/legacy_rules
	# （列入 ModAPI.BUNDLED_SKIP，默认不加载，玩家可在模组页自行启用）。
	var rules: Array = [
		ClassicRule.new(), ClockRule.new(), LoopRunsRule.new(),
		MxRule.new(), PfRule.new(), RlRule.new(), QdRule.new(),
		DtRule.new(), TotalMinesRule.new(),
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

	## 布雷：分层采样优先（v2.9.3），纯随机+过滤兜底。
	## 大密度（8×8/26 雷 = 40.6%）下纯随机单次全窗口过滤通过率极低（首轮量产实测
	## g_pf/8x8、pf_classic/8x8 等 110 seed 仅 2~3 关，接受率 ~2.5%），根因是随机布雷
	## 雷团簇 → 某 2×2 窗口 3+ 雷概率高。分层采样按对齐 2×2 块均衡分配（每块 ≤2 雷
	## → 对齐窗口必过，仅跨界窗口可能违约需过滤），通过率高一个量级。
	## 约束语义不变：两种采样都经 _ok 全窗口校验；确定性不受影响（全部走 _rng）。
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
				# 容量：满 2×2 块 2 雷；边缘残块（1×2/2×1/1×1）只给 1——残块满填（两格全雷）
				# 会与相邻块边界组成 3+ 雷窗口（9×9 实测通过率仅 3% 的根因）。
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
		# 块内随机取位
		var out: Array[Vector2i] = []
		for bi in blocks.size():
			if alloc[bi] <= 0:
				continue
			var pool: Array = blocks[bi].duplicate()
			for i in range(pool.size() - 1, 0, -1):
				var j := rng.randi_range(0, i)
				var t = pool[i]
				pool[i] = pool[j]
				pool[j] = t
			for i in alloc[bi]:
				out.append(pool[i])
		return out

	## 镜像分层采样（v2.9.3）：mx+pf 组合专用。多 G 布雷走 find_solution 的第一可行解
	## 结构差 → mx_pf/5x5、6x6、8x8 量产接受率趋零（110 seed 零新增）。本方法左半区
	## 2×2 块分层布雷 + 中轴列补雷 + 右半镜像——镜像自动满足 mx；PF 窗口在镜像下封闭
	## （原窗口过 ⇒ 镜像窗口过），跨中轴窗口由 _ok 过滤。雷数结构 count = 2k + j
	## （j = 中轴列雷数，与 count 同奇偶；偶数列 j=0）。
	func place_mines_mirrored(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		for _attempt in 200:
			var mines := _mirrored_stratified(rng, cols, rows, count)
			if not mines.is_empty() and _ok(mines, cols, rows):
				return mines
		return []

	static func _mirrored_stratified(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var half := int(cols / 2)
		var has_axis := (cols % 2 == 1)
		var axis_cells: Array[Vector2i] = []
		if has_axis:
			for r in rows:
				axis_cells.append(Vector2i(half, r))
		# j（中轴雷数）与 count 同奇偶，且 0 ≤ j ≤ min(count, 中轴格数)
		var j_options: Array[int] = []
		var j0 := count % 2
		if not has_axis:
			j0 = 0
		var jj := j0
		while jj <= mini(count, axis_cells.size()):
			j_options.append(jj)
			jj += 2
		if j_options.is_empty() or (not has_axis and count % 2 != 0):
			return []
		var j_pick: int = j_options[rng.randi_range(0, j_options.size() - 1)]
		var k := (count - j_pick) / 2
		if k < 0:
			return []
		# 左半区分层采样 k 雷（_stratified_mines 的 cols=half；k=0 时直接空盘）
		var left_mines: Array[Vector2i] = []
		if k > 0:
			left_mines = _stratified_mines(rng, half, rows, k)
			if left_mines.is_empty():
				return []
		# 中轴列随机 j_pick 雷
		var axis_pool: Array = axis_cells.duplicate()
		for i in range(axis_pool.size() - 1, 0, -1):
			var ja := rng.randi_range(0, i)
			var ta = axis_pool[i]
			axis_pool[i] = axis_pool[ja]
			axis_pool[ja] = ta
		var mines := {}
		for m in left_mines:
			mines[m] = true
			mines[Vector2i(cols - 1 - m.x, m.y)] = true
		for i in j_pick:
			mines[axis_pool[i]] = true
		var out: Array[Vector2i] = []
		for m in mines:
			out.append(m)
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
		# v3.x 零值修复对齐（与 ClueEngine._loop_runs_value 同步）：
		# runs[i] ⟺ cur_i ∧ ¬prev_i 已由上方约束钉死，故 Σruns 由格状态唯一决定。
		# 全雷环没有 0→1 上升沿（Σruns=0）但语义值 = 1，按值分支编码：
		#   值 0 ⟺ 空环：Σruns == 0，且至少一格非雷（排除全雷环）；
		#   值 1 ⟺ 恰一段 或 全雷环：Σruns ≤ 1（段起点两两互斥）且至少一格雷；
		#   值 ≥ 2：Σruns == value（空环 / 全雷环自动排除）。
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
		if value != 0:
			return []
		return RulePlugin.dirs_to_neighbors(pos, grid_size, ClueEngine.ring_dirs())


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
	## 全偶盘（无中央行列）：四象限各 k 雷，总雷数 = 4k，**必须是 4 的倍数**。
	## R07 固定雷数 6×6=14 / 8×8=26 不是 4 的倍数 → 数学上 UNSAT。
	## 旧代码 count -= count % 4 偷偷调平（14→12、26→24），会产出「雷数不符」的关（实测 6×6 出 12 雷），
	## 直接违反 R07 固定雷数红线。改为显式判不可行（返回空，交给上层重试/跳过该尺寸）。
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
		if (rows % 2 == 0) and (cols % 2 == 0) and count % 4 != 0:
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
