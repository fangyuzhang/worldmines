# spec_rule_plugin.gd —— 把「声明式变体规格」适配成一等规则插件
#
# 为什么 place_mines 返回空数组（禁暴力设计，勿改成启发式布雷）：
#   本平台的关卡生成是「CP-SAT 在约束集上求一个解」，布雷是求解的产物而非前置输入。
#   规格玩家（可能由 AI 生成）既不该、也不能指定布雷算法；若这里返回构造式布局，
#   等于把暴力/启发式布雷带进平台——既不可验证，也会绕过约束门禁。
#   返回 [] ⇒ 生成器走 CP-SAT find_solution（core/rule_oracle.gd build_spec 产出的约束集），
#   由求解器保证雷布局满足全部线索与全局约束。
#
# 与 core/spec_schema.gd 的分工：那边只做静态校验，本文件负责运行时 IR 组装与求值。
#
# 几何（v4.x，依据 core/puzzle_generator.gd:512-522 与 core/rule_plugin.gd:140-153）：
#   · refs="topo"：邻域 = 棋盘拓扑邻接表（topo.get_neighbors(pos)）。这是**唯一**允许在
#     非矩形盘上与 geometry="adj_generic" 配用的形态；正向求值走 compute_clue_topo。
#   · refs=[{dx,dy},...]：固定偏移，只允许 geometry="rect_only"；正向求值走 compute_clue。
#   校验器强制上述配对，故任何构造成功的实例都自洽。
class_name SpecRulePlugin
extends RulePlugin


var _spec: Dictionary = {}
var _id: StringName = &""
var _title: String = ""
var _has_clue: bool = false
## true = refs 为 "topo"（邻接表下标）；false = 固定偏移数组（_refs）。
var _refs_topo: bool = false
var _refs: Array[Vector2i] = []
var _expr: Dictionary = {}
var _max: int = 0
var _empty_value: int = 0
var _globals: Array = []
var _aux: Array = []


# ==================== 对外构造 ====================

## 解析 + 校验 + 构造插件。返回 {"ok","errors","rule","warnings","warning_codes"}（后两者同序同长）。
## 失败时 rule 为 null，不产生任何副作用（不触碰注册表）。
static func from_json(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return {"ok": false, "errors": PackedStringArray(["JSON 解析失败——spec 必须是合法 JSON 对象（常见原因：单引号 / 注释 / 中文全角标点）"]), "rule": null, "warnings": PackedStringArray(), "warning_codes": PackedStringArray()}
	if not (parsed is Dictionary):
		return {"ok": false, "errors": PackedStringArray(["spec 顶层必须是 JSON 对象（收到 %s）" % str(parsed)]), "rule": null, "warnings": PackedStringArray(), "warning_codes": PackedStringArray()}
	var v := SpecSchema.validate(parsed)
	if not bool(v["ok"]):
		return {"ok": false, "errors": v["errors"], "rule": null, "warnings": v["warnings"], "warning_codes": v["warning_codes"]}
	var p := SpecRulePlugin.new()
	p._apply_spec(parsed)
	return {"ok": true, "errors": PackedStringArray(), "rule": p, "warnings": v["warnings"], "warning_codes": v["warning_codes"]}


## 校验 → 注册进 RuleRegistry.default()。返回 {"ok","errors","id","warnings","warning_codes"}。
## 失败路径**不留痕**：validate 已拒重复 id，这里再查一次，绝不覆盖既有规则。
static func register_from_json(text: String) -> Dictionary:
	var res := from_json(text)
	if not bool(res["ok"]):
		return {"ok": false, "errors": res["errors"], "id": "", "warnings": res["warnings"], "warning_codes": res["warning_codes"]}
	var rule: SpecRulePlugin = res["rule"]
	var id := String(rule.get_rule_id())
	var reg := RuleRegistry.default()
	if reg.resolve(StringName(id)) != null:
		return {"ok": false, "errors": PackedStringArray(["id \"%s\" 已被注册——规格 id 必须全局唯一" % id]), "id": "", "warnings": res["warnings"], "warning_codes": res["warning_codes"]}
	if not reg.register(rule):
		return {"ok": false, "errors": PackedStringArray(["注册失败（RuleRegistry 拒绝 id \"%s\"）" % id]), "id": "", "warnings": res["warnings"], "warning_codes": res["warning_codes"]}
	return {"ok": true, "errors": PackedStringArray(), "id": id, "warnings": res["warnings"], "warning_codes": res["warning_codes"]}


func _apply_spec(spec: Dictionary) -> void:
	_spec = spec
	_id = StringName(str(spec.get("id", "")))
	_title = str(spec.get("title", ""))
	_globals = spec.get("globals", [])
	_aux = spec.get("aux", [])
	_has_clue = spec.has("clue")
	if _has_clue:
		var clue: Dictionary = spec.get("clue", {})
		var refs_v: Variant = clue.get("refs")
		_refs = []
		_refs_topo = refs_v is String   # 校验器只放行 "topo"
		if not _refs_topo:
			for r in refs_v:
				_refs.append(Vector2i(int(r["dx"]), int(r["dy"])))
		_expr = clue.get("expr", {})
		# topo 形态没有固定 refs 数组，缺省上界取 8（内置计数语义的安全上界）。
		_max = int(clue.get("max", 8 if _refs_topo else _refs.size()))
		_empty_value = int(clue.get("empty_value", 0))


# ==================== 标识 / 元信息 ====================

func get_rule_id() -> StringName:
	return _id


func get_kind() -> String:
	# 有 clue ⇒ 作为格子级线索注册（其 globals 走 build_global_clue_constraints）；
	# 纯 globals ⇒ 作为棋盘级规则注册。
	return KIND_CLUE if _has_clue else KIND_GLOBAL


func describe() -> Dictionary:
	return {"name": _title, "rule_text": "声明式规格 %s（clue=%s, globals=%d）" % [String(_id), str(_has_clue), _globals.size()]}


func spec_id() -> StringName:
	return _id


func spec_title() -> String:
	return _title


## 本实例的规格原文（深拷贝）。
## 【为什么需要】编辑器要判"注册表里那个 id 上是不是**同一条**规格"：用户按完「试玩」/「用这个配方」
## 之后，`SpecSchema.validate` 的"id 必须全局唯一"会把这条规格**自己**判成错，
## 于是试玩/验证/打包一起报一条用户根本修不了的"已被注册"（2026-10-02 实测）。
## 判"同源"而不是"有个规格规则占着这个 id"：用户手改成另一条同 id 的规格时，
## 注册表里那条是旧版本，必须照实报错，否则会静默用到旧规则。
func spec_source() -> Dictionary:
	return _spec.duplicate(true)


## 【主代理 2026-10-01 修复：topo 形态的"跨生成/载入稳定性"】
## 缺陷：`refs="topo"` 的 `ref i` 若直接绑定 `topo.get_neighbors(pos)` 的**插入序**，
## 就会在序列化往返时漂移 —— 生成期内存里的邻接表插入序 与 落盘边表(`topology.adjacency`)
## 重新装载后重建的 `_adj` 顺序**不保证一致**（core/puzzle_generator 落盘 / core/adjacency_grid
## 重建各自的写入顺序可不同）⇒ 载入侧 `ref i` 指向了**别的邻居**：生成期验证通过的关，
## 载入后线索值与约束错位，可能直接不可解，而且**全程不报错**。
## 修法：本规则**自己定义并固定**邻接序 = 按 (y, x) 升序（与邻接表的物理存储无关），
## 正向求值与约束构造全部走这个序 ⇒ 自洽、跨序列化稳定、且与平台的"邻域计数"口径（无序）相容。
static func _sorted_neighbors(nbs: Array) -> Array[Vector2i]:
	# 注意返回**带类型**数组：下游 `_ir_clue_expr_topo(expr, Array[Vector2i])` 是强类型形参，
	# 返回无类型 Array 会在运行期抛 "does not have the same element type"（本仓已踩过两次）。
	var arr: Array[Vector2i] = []
	for nb in nbs:
		arr.append(nb)
	arr.sort_custom(func(a, b):
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	return arr


## 几何声明。拓扑形态只依赖邻接表（任意棋盘可用）；固定偏移依赖矩形行列（仅矩形盘）。
## 与校验器的 refs/geometry 配对约束互为双保险；常量取自 core/rule_plugin.gd:47-48。
func geometry_kind() -> int:
	return GEO_ADJ_GENERIC if _refs_topo else GEO_RECT_ONLY


func declares() -> Dictionary:
	# v1 不支持规格级隐藏态（export/import_hidden_state 沿用基类空实现）。
	return {}


# ==================== 线索规则契约 ====================

## 矩形正向求值（mine_set 兼容 Dictionary 与 Array[Vector2i]）。
## refs="topo" 形态在此无意义（ref 需映射到运行时邻接表）⇒ 返回 empty_value；
## 平台在异形盘改走 compute_clue_topo（core/puzzle_generator.gd:512-522），校验阶段已就此告警。
func compute_clue(mine_set, pos: Vector2i, grid_size: Vector2i) -> Variant:
	if not _has_clue:
		return _empty_value
	if _refs_topo:
		return _empty_value
	return CPIR.eval_expr(_ir_clue_expr(_expr, pos, grid_size), _asg_from(mine_set))


## 异形盘正向求值：ref i 映射到本格拓扑邻接表第 i 个邻居（无该邻居 ⇒ 0），再按 expr 求值。
## 与 build_clue_constraints 同源 ⇒ 任意值域（加权/压缩）都「值算一套、约束另一套」不会发生；
## 契约见 core/rule_plugin.gd:140-153（基类默认 = 数拓扑邻域雷数）。
func compute_clue_topo(mine_set: Dictionary, pos: Vector2i, topo: GridInterface, _grid_size: Vector2i) -> Variant:
	if not _has_clue:
		return _empty_value
	if not _refs_topo:
		# 固定偏移形态在拓扑盘上语义不成立（校验器已禁止该组合）⇒ 无值。
		return _empty_value
	if topo == null:
		# 守卫（与基类默认实现同纪律）：不得崩。
		return _empty_value
	return CPIR.eval_expr(_ir_clue_expr_topo(_expr, _sorted_neighbors(topo.get_neighbors(pos))), _asg_from(mine_set))


## 拓扑盘上的 0 值扩散：**只有"纯邻域和且覆盖本格全部邻居"的规格**才等同于计数语义，
## 才允许按拓扑邻域泛洪；其余（加权 / 压缩 / 只引用前 K 个邻居）一律**不扩散**。
## 为什么保守：泛洪等于平台替作者宣称"这些格安全"。规则的 0 值语义一旦不是计数，
## 泛洪就会免费翻开不在线索保证范围内的格（难度低于画像、与提示结论不一致）。
func zero_safe_neighbors_topo(pos: Vector2i, topo: GridInterface, value: Variant = null) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if topo == null or not (value is int) or int(value) != 0:
		return out
	if not _refs_topo:
		return out
	var used := _pure_count_refs()
	if used <= 0:
		return out
	var nbs: Array[Vector2i] = []
	nbs.assign(topo.get_neighbors(pos))
	# 覆盖度：只引用前 K 个邻居时，**没被引用的邻居不在这条线索的保证范围内** ⇒ 不泛洪。
	# ⚠ 不要用 `_max` 判覆盖度：它是**值域上界**（topo 形态缺省 8，见 `_apply_spec`），
	# 与"引用了几个邻居"无关——本函数的第一版就是用它判的，结果"只引用前 2 个邻居"
	# 也被判成覆盖充足并泛了洪（由 test_topo_zero_flood.gd 当场抓到）。
	if used < nbs.size():
		return out
	out.assign(nbs)
	return out


## expr 若等价于"对 ref 0..K-1 各一次求和"（= 计数语义）则返回 K，否则返回 -1。
## 只看形状不看数值：`sum` 的 xs 必须恰为 `{"t":"ref","i":0..K-1}` 各一次（连续、不重复）。
## `wsum`（加权和）一律返回 -1 —— 权重全 1 时才等价于计数，但那属于"作者明说"的范畴，
## 这里不做数值推断（保守方向：不扩散）。
func _pure_count_refs() -> int:
	if str(_expr.get("t", "")) != "sum":
		return -1
	var xs: Variant = _expr.get("xs", [])
	if not (xs is Array):
		return -1
	var seen := {}
	for e in xs:
		if not (e is Dictionary):
			return -1
		var d: Dictionary = e
		if str(d.get("t", "")) != "ref":
			return -1
		var i := int(d.get("i", -1))
		if i < 0 or seen.has(i):
			return -1
		seen[i] = true
	var k := seen.size()
	if k == 0:
		return -1
	for i in k:
		if not seen.has(i):
			return -1   # 索引不连续（如只有 ref 0 与 ref 3）⇒ 不能当计数语义
	return k


func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
	if not _has_clue:
		return
	var expr: Dictionary
	if _refs_topo:
		# b 设了 topology 时 neighbors 忽略 dirs、直接返回邻接表（core/rule_builder.gd:77-85）。
		# 必须走 _sorted_neighbors：与 compute_clue_topo 用**同一个序**，否则值/约束错位（见该函数注释）。
		expr = _build_clue_expr_topo(_expr, b, _sorted_neighbors(b.neighbors(pos, [])))
	else:
		expr = _build_clue_expr(_expr, b, pos)
	b.add_eq(expr, b.const_expr(int(value)))


func supports_mask() -> bool:
	# 区间语义 [lo,hi] 对任意计数表达式成立（无论 expr 是 8 邻和、加权和还是拓扑邻域和）。
	return true


func build_interval_constraints(b: RuleBuilder, pos: Vector2i, lo: int, hi: int) -> void:
	if not _has_clue:
		return
	var expr: Dictionary
	if _refs_topo:
		expr = _build_clue_expr_topo(_expr, b, _sorted_neighbors(b.neighbors(pos, [])))
	else:
		expr = _build_clue_expr(_expr, b, pos)
	b.add_le(b.const_expr(lo), expr)
	b.add_le(expr, b.const_expr(hi))


func value_upper_bound(_grid_size: Vector2i) -> int:
	return _max if _has_clue else 8


# ==================== 全局约束契约 ====================

func build_global_constraints(b: RuleBuilder) -> void:
	_apply_globals(b)


## 作为 clue 规则时，RuleOracle.build_spec 走的是这个钩子（core/rule_oracle.gd:200）。
## 与 build_global_constraints 同源，保证「规格里的 globals」在两种注册路径下都生效。
func build_global_clue_constraints(b: RuleBuilder) -> void:
	_apply_globals(b)


## 构造式布雷禁用（见文件头注释）。返回空 ⇒ 交给 CP-SAT 兜底。
func place_mines(_rng: RandomNumberGenerator, _cols: int, _rows: int, _count: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	return out


# ==================== 内部：雷集 → asg ====================

func _asg_from(mine_set) -> Dictionary:
	var asg := {}
	if mine_set is Array:
		for p in mine_set:
			if p is Vector2i:
				asg[CPIR.cell_key(p.y, p.x)] = 1
	elif mine_set is Dictionary:
		for p in mine_set:
			if p is Vector2i and mine_set[p]:
				asg[CPIR.cell_key(p.y, p.x)] = 1
	return asg


# ==================== 内部：固定偏移形态的 IR 实例化 ====================

## clue.expr → CPIR 表达式：ref i 映射到 pos+refs[i]；越界按非雷 0（与 core/rule_builder.gd:55 同语义）。
func _ir_clue_expr(e: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Dictionary:
	match str(e.get("t", "")):
		"const":
			return CPIR.const_expr(int(e.get("v", 0)))
		"ref":
			var i := int(e.get("i", -1))
			if i < 0 or i >= _refs.size():
				return CPIR.const_expr(_empty_value)
			var col := pos.x + _refs[i].x
			var row := pos.y + _refs[i].y
			if col < 0 or col >= grid_size.x or row < 0 or row >= grid_size.y:
				return CPIR.const_expr(0)
			return CPIR.cell_var(row, col)
		"sum":
			var xs: Array = []
			for x in e.get("xs", []):
				xs.append(_ir_clue_expr(x, pos, grid_size))
			return CPIR.sum(xs)
		"wsum":
			var ws: Array = e.get("ws", [])
			var xs2: Array = []
			for x in e.get("xs", []):
				xs2.append(_ir_clue_expr(x, pos, grid_size))
			return CPIR.wsum(ws, xs2)
	push_error("SpecRulePlugin: clue.expr 含未知节点 \"%s\"（校验器应已拦截）" % str(e.get("t", "")))
	return CPIR.const_expr(_empty_value)


## clue.expr → RuleBuilder IR（固定偏移形态）。越界 ref 由 b.cell_var 归为 const 0。
func _build_clue_expr(e: Dictionary, b: RuleBuilder, pos: Vector2i) -> Dictionary:
	match str(e.get("t", "")):
		"const":
			return b.const_expr(int(e.get("v", 0)))
		"ref":
			var off := _refs[int(e.get("i", 0))]
			return b.cell_var(pos.y + off.y, pos.x + off.x)
		"sum":
			var xs: Array = []
			for x in e.get("xs", []):
				xs.append(_build_clue_expr(x, b, pos))
			return b.sum(xs)
		"wsum":
			var xs2: Array = []
			for x in e.get("xs", []):
				xs2.append(_build_clue_expr(x, b, pos))
			return b.wsum(e.get("ws", []), xs2)
	push_error("SpecRulePlugin: clue.expr 含未知节点 \"%s\"（校验器应已拦截）" % str(e.get("t", "")))
	return b.const_expr(_empty_value)


# ==================== 内部：拓扑形态的 IR 实例化 ====================

## clue.expr → CPIR 表达式：ref i 取自本格邻接表 nbs（下标越界 ⇒ const 0）。
func _ir_clue_expr_topo(e: Dictionary, nbs: Array[Vector2i]) -> Dictionary:
	match str(e.get("t", "")):
		"const":
			return CPIR.const_expr(int(e.get("v", 0)))
		"ref":
			var i := int(e.get("i", -1))
			if i < 0 or i >= nbs.size():
				return CPIR.const_expr(0)
			return CPIR.cell_var(nbs[i].y, nbs[i].x)
		"sum":
			var xs: Array = []
			for x in e.get("xs", []):
				xs.append(_ir_clue_expr_topo(x, nbs))
			return CPIR.sum(xs)
		"wsum":
			var ws: Array = e.get("ws", [])
			var xs2: Array = []
			for x in e.get("xs", []):
				xs2.append(_ir_clue_expr_topo(x, nbs))
			return CPIR.wsum(ws, xs2)
	push_error("SpecRulePlugin: clue.expr 含未知节点 \"%s\"（校验器应已拦截）" % str(e.get("t", "")))
	return CPIR.const_expr(_empty_value)


## clue.expr → RuleBuilder IR（拓扑形态）。nbs 是 b.neighbors(pos)（邻接表）。
func _build_clue_expr_topo(e: Dictionary, b: RuleBuilder, nbs: Array[Vector2i]) -> Dictionary:
	match str(e.get("t", "")):
		"const":
			return b.const_expr(int(e.get("v", 0)))
		"ref":
			var i := int(e.get("i", -1))
			if i < 0 or i >= nbs.size():
				return b.const_expr(0)
			return b.cell_var_pos(nbs[i])
		"sum":
			var xs: Array = []
			for x in e.get("xs", []):
				xs.append(_build_clue_expr_topo(x, b, nbs))
			return b.sum(xs)
		"wsum":
			var xs2: Array = []
			for x in e.get("xs", []):
				xs2.append(_build_clue_expr_topo(x, b, nbs))
			return b.wsum(e.get("ws", []), xs2)
	push_error("SpecRulePlugin: clue.expr 含未知节点 \"%s\"（校验器应已拦截）" % str(e.get("t", "")))
	return b.const_expr(_empty_value)


# ==================== 内部：globals 翻译 ====================

func _apply_globals(b: RuleBuilder) -> void:
	if _globals.is_empty() and _aux.is_empty():
		return
	# aux 必须按 spec 声明顺序创建：{"t":"aux","i":k} 的 k 即创建序号。
	# 记录 b 实际返回的变量节点（而非假设编号从 0 起）——
	# 这样本插件与其它全局规则共用同一 builder 时，编号偏移也不会错位。
	var aux_nodes: Array = []
	for a in _aux:
		if str(a.get("kind", "bool")) == "int":
			aux_nodes.append(b.int_var(int(a.get("lo", 0)), int(a.get("hi", 0))))
		else:
			aux_nodes.append(b.bool_var())
	for g in _globals:
		b.add(_transl_node(g, b, aux_nodes))


func _transl_node(n: Dictionary, b: RuleBuilder, aux_nodes: Array) -> Dictionary:
	var t := str(n.get("t", ""))
	match t:
		"cell":
			var r := int(n.get("r", 0))
			var c := int(n.get("c", 0))
			if not b.in_board(r, c):
				push_error("SpecRulePlugin: globals 的 cell(%d,%d) 越界（盘面 %dx%d）——校验器只能查负号，盘内检查在建盘时执行" % [r, c, b.rows, b.cols])
				return CPIR.const_expr(0)
			return b.cell_var(r, c)
		"aux":
			var i := int(n.get("i", -1))
			if i < 0 or i >= aux_nodes.size():
				push_error("SpecRulePlugin: globals 的 aux 索引 %d 越界（aux 只声明了 %d 项）" % [i, aux_nodes.size()])
				return CPIR.const_expr(0)
			return aux_nodes[i]
		"const":
			return b.const_expr(int(n.get("v", 0)))
		"sum":
			var xs: Array = []
			for x in n.get("xs", []):
				xs.append(_transl_node(_as_node(x), b, aux_nodes))
			return b.sum(xs)
		"wsum":
			var xs2: Array = []
			for x in n.get("xs", []):
				xs2.append(_transl_node(_as_node(x), b, aux_nodes))
			return b.wsum(n.get("ws", []), xs2)
		"lin":
			var xs3: Array = []
			for x in n.get("xs", []):
				xs3.append(_transl_node(_as_node(x), b, aux_nodes))
			return b.lin(n.get("ws", []), xs3, int(n.get("c", 0)))
		"not":
			return b.not_lit(_transl_node(_as_node(n.get("x")), b, aux_nodes))
		"eq":
			return CPIR.c_eq(_transl_node(_as_node(n.get("a")), b, aux_nodes), _transl_node(_as_node(n.get("b")), b, aux_nodes))
		"le":
			return CPIR.c_le(_transl_node(_as_node(n.get("a")), b, aux_nodes), _transl_node(_as_node(n.get("b")), b, aux_nodes))
		"lt":
			return CPIR.c_lt(_transl_node(_as_node(n.get("a")), b, aux_nodes), _transl_node(_as_node(n.get("b")), b, aux_nodes))
		"imp":
			return CPIR.c_imp(_transl_node(_as_node(n.get("a")), b, aux_nodes), _transl_node(_as_node(n.get("b")), b, aux_nodes))
		"iff":
			return CPIR.c_iff(_transl_node(_as_node(n.get("a")), b, aux_nodes), _transl_node(_as_node(n.get("b")), b, aux_nodes))
		"bool_or":
			return CPIR.c_bool_or(_transl_lits(n.get("lits", []), b, aux_nodes))
		"bool_and":
			return CPIR.c_bool_and(_transl_lits(n.get("lits", []), b, aux_nodes))
		"all_diff":
			var xs4: Array = []
			for x in n.get("xs", []):
				xs4.append(_transl_node(_as_node(x), b, aux_nodes))
			return CPIR.c_all_diff(xs4)
		"enforce":
			return CPIR.c_enforce(_transl_lits(n.get("lits", []), b, aux_nodes), _transl_node(_as_node(n.get("c")), b, aux_nodes))
	push_error("SpecRulePlugin: globals 含不支持节点 \"%s\"（校验器应已拦截）" % t)
	return CPIR.const_expr(0)


func _transl_lits(lits: Variant, b: RuleBuilder, aux_nodes: Array) -> Array:
	var out: Array = []
	if lits is Array:
		for l in lits:
			out.append(_transl_node(_as_node(l), b, aux_nodes))
	return out


## 校验器保证子节点是 Dictionary；这里做一次显式转换以固定静态类型。
func _as_node(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}
