# core/shape_dag.gd —— 形状依赖图（DAG）：形状链 / 布尔链的依赖建模、环检测、求值计划与序列化。
#
# 为什么必须有（文档「三、形状系统」原文要求）：
#   布尔运算链与嵌套形状天然形成依赖关系（"对 A、B 做并集得到 C" ⇒ C 依赖 A、B）。
#   若用**列表**存这条链，后期加「删除中间形状」时整条链会**悬空**（列表答不出"谁依赖被删者"）；
#   用**有向无环图**存，「谁依赖我 / 删了我谁悬空 / 先算什么」全是图上的可判定问题。
#   故本模块第一天就把依赖建成图，并在**加边的那一刻**拒绝环（有环 = 求值顺序根本不存在）。
#
# 术语（用真实概念，不造词）：
#   · 节点 = 一个形状：id + kind + shape + params。
#       kind = "primitive"（原子形状：矩形 rect / 圆 circle / N边形 ngon / 星形 star /
#                            环形 ring / 扇形 sector / 手绘 freehand / 文字 text）
#            | "boolean"  （布尔运算：并 union / 交 intersect / 差 difference / 异或 xor）
#   · 边 = 依赖，方向 **父 → 子**：「C 依赖 A」记作 A → C（A 是 C 的输入，C 是 A 的依赖方）。
#     故 dependencies_of(C) = C 的直接输入；dependents_of(A) = 一旦 A 没了就会被悬空的子孙。
#     `difference`（差集）这类**有序**运算靠"输入顺序"表达语义 ⇒ 输入一律保留**加边顺序**。
#
# 纯逻辑（硬约束）：
#   · 不 extends Node、不碰场景树、不 preload 任何 ui/*；除自身状态外无副作用。
#   · 所有顺序**可复现**：节点顺序一律按插入顺序（`_order`），绝不依赖哈希遍历顺序。
#     topo_order 的稳定规则 = 同一入度就绪时按插入顺序取（见 _insert_by_order）。
#   · 参数量化：所有数值按 1/65536 量化后再存（quantize_value），跨机器/跨进程逐位一致。
#
# 序列化与版本（version 只增不改，旧数据始终可读）：
#   to_dict() → {"version", "nodes":[...], "edges":[...]}；from_dict() 读回。
#   · version > 本模块 VERSION → **拒绝**（未知的新格式，宁可报错也不猜）；
#   · version 缺失（= 老数据，按 0 处理）或 < VERSION → 正常读入。
#   · from_dict 是**原子**的：任一条不合法就整体拒绝，self 保持原样（绝不落半成品）。
class_name ShapeDag
extends RefCounted

## 序列化格式版本。只增不改：改动即 +1，老数据（version 更小/缺失）一律仍可读。
const VERSION := 1
## 浮点量化步长 = 1/65536（2^-16）。所有数值参数按此栅格存储，跨机器一致。
const QUANT_STEP := 1.0 / 65536.0

const NODE_PRIMITIVE := "primitive"
const NODE_BOOLEAN := "boolean"
## 原子形状（kind = primitive）。这是**唯一的形状词汇表**：生成器/求值器的命名必须对齐这里
## （已对齐：core/shape_generator.gd 的 build_circle(radius, precision=24) /
## build_star(points, outer_radius, inner_ratio=0.5) /
## build_sector(radius: int, start_deg: float, end_deg: float)）。
## 注意 build_sector 的角度口径：0° = +x、向 +y（**行向下**）为正，要求 0 ≤ start_deg < end_deg ≤ 360
## （不跨 0°）；参数名就是 radius / start_deg / end_deg，不是 sectors / angle_span。
## 产物与既有族同接口，失败时才有 error 键 ⇒ 执行器判失败用 String(topo.get("error", "")) != ""，
## 不要用 has("error")（成功产物没有该键，与既有族一致）。
## 两处**已知缺口**（本模块只登记词汇，不负责补生成器）：
##   · "ngon" —— 尚无正 N 边形生成器（shape_generator 未提供）；
##   · "ring" —— 此处语义是**环形 annulus**（内圆挖空），**不是** ShapeGenerator.build_ring 的
##     「同心环盘（带角向闭环）」。求值 ring primitive 时切勿直接拿 build_ring 顶替：
##     annulus 是单个带洞形状，环盘是一圈可绕回的格区，几何与拓扑都不同。
## 这两个缺口**不靠注释防呆**：见下方 primitive_to_builder()（ngon ⇒ ok=false + 原因；
## ring ⇒ 禁止映射到 build_ring）与 test/unit/test_shape_dag_mapping.gd 的红灯断言。
const PRIMITIVE_SHAPES: Array[String] = [
	"rect", "circle", "ngon", "star", "ring", "sector", "freehand", "text",
]
## 布尔运算（kind = boolean）。名字**逐字对齐** core/shape_boolean.gd 的 OP_* 常量
## （union / intersect / difference / xor），否则 DAG 节点与求值器之间会漂移出两套叫法。
const BOOLEAN_OPS: Array[String] = ["union", "intersect", "difference", "xor"]
## DAG 形状 → core/shape_generator.gd 构建器名：**只登记语义已逐字核对一致**的形状。
## 未登记 ⇒ 没有可用构建器（不是"用空几何兜底"），必须走 primitive_to_builder() 的失败分支。
const BUILDER_BY_SHAPE := {
	"circle": "build_circle",   # (radius: int, precision: int = 24)
	"star": "build_star",       # (points: int, outer_radius: int, inner_ratio: float = 0.5)
	"sector": "build_sector",   # (radius: int, start_deg: float, end_deg: float)
}

var _nodes: Dictionary = {}       ## id -> {"id","kind","shape","params"}
var _order: Array[String] = []    ## 节点插入顺序（拓扑稳定性的唯一依据）
var _parents: Dictionary = {}     ## id -> Array[String]：直接输入，按加边顺序
var _children: Dictionary = {}    ## id -> Array[String]：直接被依赖方，按加边顺序
var _edges: Array = []            ## [{"from": parent, "to": child}]，加边顺序


# ============================== 建图 ==============================

## 加一个原子形状节点（如矩形 / 圆 / N边形 / 星形 / 环形 / 扇形 / 手绘 / 文字）。
## 返回 {"ok": bool, "error": String}（成功时 error = ""）。
func add_primitive(id: String, shape: String, params: Dictionary = {}) -> Dictionary:
	return _add_node(id, NODE_PRIMITIVE, shape, params)


## 加一个布尔运算节点（并 / 交 / 差 / 异或）。输入由后续 add_edge 声明。
func add_boolean(id: String, op: String, params: Dictionary = {}) -> Dictionary:
	return _add_node(id, NODE_BOOLEAN, op, params)


## 加一条依赖边：父（输入）→ 子（结果）。会成环 / 自依赖 / 重复 → **拒绝**，原因可读。
## 拒绝时图保持原样（先加后验，发现环立刻回滚这条边）。
func add_edge(parent_id: String, child_id: String) -> Dictionary:
	if not _nodes.has(parent_id):
		return _err("未知节点（父）：%s" % parent_id)
	if not _nodes.has(child_id):
		return _err("未知节点（子）：%s" % child_id)
	if parent_id == child_id:
		return _err("自依赖非法：%s 不能依赖自身（环：%s）" % [parent_id, _cycle_text([parent_id])])
	if (_children[parent_id] as Array).has(child_id):
		return _err("边已存在：%s → %s" % [parent_id, child_id])
	_children[parent_id].append(child_id)
	_parents[child_id].append(parent_id)
	_edges.append({"from": parent_id, "to": child_id})
	var cycle := detect_cycle()
	if not cycle.is_empty():
		_remove_edge_raw(parent_id, child_id)
		return _err("拒绝加边 %s → %s：会形成循环依赖 %s" % [parent_id, child_id, _cycle_text(cycle)])
	return _ok()


## 删一条依赖边。不存在的边 → 拒绝（不静默成功）。
func remove_edge(parent_id: String, child_id: String) -> Dictionary:
	if not _nodes.has(parent_id) or not (_children.get(parent_id, []) as Array).has(child_id):
		return _err("边不存在：%s → %s" % [parent_id, child_id])
	_remove_edge_raw(parent_id, child_id)
	return _ok()


# ============================== 查询 ==============================

func has_node(id: String) -> bool:
	return _nodes.has(id)


func node_count() -> int:
	return _order.size()


## 节点 id，按插入顺序（可复现）。
func node_ids() -> Array:
	return _order.duplicate()


## 单个节点的**副本**（id / kind / shape / params），未知 id → {}。
func node(id: String) -> Dictionary:
	if not _nodes.has(id):
		return {}
	var n: Dictionary = _nodes[id]
	return n.duplicate(true)


## 全部节点的副本，按插入顺序。
func nodes() -> Array:
	var out: Array = []
	for id in _order:
		out.append(node(id))
	return out


## 全部边（{"from","to"} 副本），按加边顺序。
func edges() -> Array:
	return _edges.duplicate(true)


## C 的直接输入（父），按加边顺序 —— 有序布尔（差集）的语义顺序。
func dependencies_of(id: String) -> Array:
	if not _nodes.has(id):
		return []
	return (_parents[id] as Array).duplicate()


## 一旦 id 被删就会被**悬空**的全部子孙（传递闭包，不含 id 自己），按插入顺序。
func dependents_of(id: String) -> Array:
	if not _nodes.has(id):
		return []
	var seen := {id: true}
	var queue: Array = [id]
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		for child in _children.get(cur, []):
			if seen.has(str(child)):
				continue
			seen[str(child)] = true
			queue.append(child)
	var out: Array = []
	for nid in _order:
		if nid != id and seen.has(nid):
			out.append(nid)
	return out


## id → 每个受影响叶子节点的**依赖链**（路径数组），BFS 序 = 先短后长、同长度按加边顺序。
## 用于"删除会悬空哪些链"的可读报告（模块只提供能力，删不删由调用方定）。
func chains_of(id: String) -> Array:
	if not _nodes.has(id):
		return []
	var out: Array = []
	var queue: Array = [[id]]
	while not queue.is_empty():
		var path: Array = queue.pop_front()
		var cur: String = path[path.size() - 1]
		var kids: Array = _children.get(cur, [])
		if kids.is_empty():
			out.append(path)
			continue
		for child in kids:
			var next_path: Array = path.duplicate()
			next_path.append(child)
			queue.append(next_path)
	return out


## 环检测（硬要求）：返回环上节点（按环绕行方向），**空数组 = 无环**。
func detect_cycle() -> Array:
	return _find_cycle(_children, _order)


## 求值顺序：拓扑序，**稳定可复现**（同一入度按插入顺序）。有环 → 返回空数组（无合法顺序，
## 原因请用 detect_cycle()）。
func topo_order() -> Array:
	if not detect_cycle().is_empty():
		return []
	var indeg := {}
	for id in _order:
		indeg[id] = (_parents[id] as Array).size()
	var ready: Array = []
	for id in _order:
		if int(indeg[id]) == 0:
			ready.append(id)
	var out: Array = []
	while not ready.is_empty():
		var id: String = ready.pop_front()
		out.append(id)
		for child in _children[id]:
			indeg[child] = int(indeg[child]) - 1
			if int(indeg[child]) == 0:
				_insert_by_order(ready, str(child))
	return out


## 求值计划："先算什么再算什么"的步骤序列（**不真算几何**，只出计划）。
## 每步 = {"step": 1 起连续, "id", "kind", "shape", "inputs": [按加边顺序]}。
## 两次调用逐项相同（源自 topo_order 的稳定性）；有环 → 空数组。
func eval_plan() -> Array:
	var out: Array = []
	var step := 1
	for id in topo_order():
		var n: Dictionary = _nodes[id]
		out.append({
			"step": step,
			"id": id,
			"kind": n["kind"],
			"shape": n["shape"],
			"inputs": (_parents[id] as Array).duplicate(),
		})
		step += 1
	return out


# ============================== 形状 → 构建器映射（红灯） ==============================
#
# 为什么必须有这层显式映射（而不是让求值器"就近挑一个 build_*"）：
#   · 词汇表里的名字 ≠ 有生成器（本仓没有 ngon / rect / freehand / text 的构建器）；
#   · 名字相同 ≠ 语义相同（本 DAG 的 "ring" 是 annulus，与 build_ring 的环盘不是一回事）。
# 两种情况若靠"就近挑"⇒ **静默产出错几何或空几何**；空几何最难查：它会被当成
# 「形状本来就长这样」写进关卡且全程无报错。故本函数只对语义已核对一致的形状开口，
# 其余一律 ok=false + 可读原因，由调用方显式处理（**禁止静默降级成空几何**）。

## 查一个 primitive shape 该用哪个构建器。返回 {ok, kind, reason, builder_name}：
##   · ok=true  ⇒ kind="builder"，builder_name ∈ BUILDER_BY_SHAPE；
##   · ok=false ⇒ kind="unsupported"（本仓无生成器，含未知/空 shape）
##                / "semantics_mismatch"（同名不同义）；
##                builder_name 恒为 ""（调用方**不得**自行挑近似构建器）。
## ring 额外带 `forbidden_builder: "build_ring"` —— 它是**明令禁止的顶替者**，不是候选。
static func primitive_to_builder(shape: String) -> Dictionary:
	if BUILDER_BY_SHAPE.has(shape):
		return {
			"ok": true, "kind": "builder", "builder_name": str(BUILDER_BY_SHAPE[shape]),
			"reason": "",
		}
	if shape == "ring":
		return {
			"ok": false, "kind": "semantics_mismatch", "builder_name": "",
			"forbidden_builder": "build_ring",
			"reason": "「ring」在本 DAG 的语义是 **annulus**（单个内圆挖空的带洞形状）；ShapeGenerator.build_ring 是「同心环盘」——多格、带角向闭环、返回 positions+adjacency，几何形态与数据结构都不同 ⇒ 同名不同义，**不得**拿 build_ring 顶替。本仓尚无 annulus 构建器 ⇒ 显式失败（绝不静默出空几何）；annulus 构建器落地后再在此登记。",
		}
	if shape == "ngon":
		return _unsupported("「ngon」只有词汇、没有生成器：本仓未提供正 N 边形构建器（无 build_ngon）。求值 / 映射必须显式失败——禁止静默产出空几何（空几何会被误当成「形状本来就长这样」）。")
	if PRIMITIVE_SHAPES.has(shape):
		return _unsupported("形状「%s」在词汇表 PRIMITIVE_SHAPES 内，但本仓未提供对应构建器（无 build_%s）⇒ 显式失败，禁止静默出空几何。" % [shape, shape])
	return _unsupported("未知形状「%s」：既不在词汇表 PRIMITIVE_SHAPES 内，也无构建器映射 ⇒ 显式失败（不猜语义、不出空几何）。可用词汇：%s" % [shape, str(PRIMITIVE_SHAPES)])


static func _unsupported(reason: String) -> Dictionary:
	return {"ok": false, "kind": "unsupported", "builder_name": "", "reason": reason}


# ============================== 删除（两种策略，调用方选） ==============================

## 策略一 · 拒绝删除：有子孙则**拒绝**，返回会被悬空的子孙与受影响的链。
## 返回 {"ok": false, "error", "dependents": [...], "chains": [[...]]}；无子孙才真删。
func remove_node_safe(id: String) -> Dictionary:
	if not _nodes.has(id):
		return _err("未知节点：%s" % id)
	var deps := dependents_of(id)
	if not deps.is_empty():
		var r := _err("拒绝删除 %s：会悬空 %d 个子孙节点 %s" % [id, deps.size(), str(deps)])
		r["dependents"] = deps
		r["chains"] = chains_of(id)
		return r
	_remove_node_raw(id)
	return {"ok": true, "error": "", "removed": [id]}


## 策略二 · 级联删除：删掉自己 + 全部子孙（上游输入保留，只是少了一条边）。
## 返回 {"ok": true, "removed": [id, ...子孙按插入顺序]}。
func remove_node_cascade(id: String) -> Dictionary:
	if not _nodes.has(id):
		return _err("未知节点：%s" % id)
	var doomed: Array = [id]
	doomed.append_array(dependents_of(id))
	for nid in doomed:
		_remove_node_raw(nid)
	return {"ok": true, "error": "", "removed": doomed}


# ============================== 序列化 ==============================

## 落盘：{"version", "nodes":[{"id","kind","shape","params"}], "edges":[{"from","to"}]}。
## 顺序 = 插入顺序 / 加边顺序；所有数值参数再次量化（幂等 ⇒ 往返逐字段一致）。
func to_dict() -> Dictionary:
	var nodes_out: Array = []
	for id in _order:
		var n: Dictionary = _nodes[id]
		nodes_out.append({
			"id": id,
			"kind": n["kind"],
			"shape": n["shape"],
			"params": quantize_value(n["params"]),
		})
	var edges_out: Array = []
	for e in _edges:
		edges_out.append({"from": e["from"], "to": e["to"]})
	return {"version": VERSION, "nodes": nodes_out, "edges": edges_out}


## 读回（原子：任一不合法整体拒绝，self 不变）。
## version 缺失（老数据）或更小 → 可读；更大 → 拒绝（不猜新格式）。
func from_dict(data: Dictionary) -> Dictionary:
	if data.is_empty():
		return _err("数据为空")
	var ver := int(data.get("version", 0))
	if ver > VERSION:
		return _err("数据版本 %d 高于本模块支持的 %d（请先升级读取方）" % [ver, VERSION])
	var nodes_v: Variant = data.get("nodes", [])
	if not (nodes_v is Array):
		return _err("nodes 必须是数组（收到 %s）" % type_string(typeof(nodes_v)))
	var edges_v: Variant = data.get("edges", [])
	if not (edges_v is Array):
		return _err("edges 必须是数组（收到 %s）" % type_string(typeof(edges_v)))
	# 先建在临时结构上，全部合法后再整体换入 self（不留半成品）。
	var t_nodes := {}
	var t_order: Array[String] = []
	var t_parents := {}
	var t_children := {}
	var t_edges: Array = []
	for nv in nodes_v:
		if not (nv is Dictionary):
			return _err("nodes 元素必须是字典（收到 %s）" % str(nv))
		var nd: Dictionary = nv
		var id := str(nd.get("id", ""))
		var kind := str(nd.get("kind", ""))
		var shape := str(nd.get("shape", ""))
		var params_v: Variant = nd.get("params", {})
		if not (params_v is Dictionary):
			return _err("节点 %s 的 params 必须是字典" % id)
		var msg := _validate_node(id, kind, shape, t_nodes)
		if msg != "":
			return _err(msg)
		t_nodes[id] = {"id": id, "kind": kind, "shape": shape, "params": quantize_value(params_v)}
		t_order.append(id)
		t_parents[id] = []
		t_children[id] = []
	for ev in edges_v:
		if not (ev is Dictionary):
			return _err("edges 元素必须是字典（收到 %s）" % str(ev))
		var ed: Dictionary = ev
		var p := str(ed.get("from", ""))
		var c := str(ed.get("to", ""))
		if not t_nodes.has(p):
			return _err("边引用了不存在的节点（from）：%s" % p)
		if not t_nodes.has(c):
			return _err("边引用了不存在的节点（to）：%s" % c)
		if p == c:
			return _err("自依赖非法：%s" % p)
		if (t_children[p] as Array).has(c):
			return _err("边重复：%s → %s" % [p, c])
		t_children[p].append(c)
		t_parents[c].append(p)
		t_edges.append({"from": p, "to": c})
		var cycle := _find_cycle(t_children, t_order)
		if not cycle.is_empty():
			return _err("数据含循环依赖 %s" % _cycle_text(cycle))
	_nodes = t_nodes
	_order = t_order
	_parents = t_parents
	_children = t_children
	_edges = t_edges
	return _ok()


## 数值量化：float → 1/65536 栅格；int / bool / String 原样；Array / Dictionary 递归；
## Vector2 → {"x","y"}（量化）；Vector2i → {"x","y"}。其余类型原样返回（调用方自行保证 JSON 可存）。
static func quantize_value(v: Variant) -> Variant:
	if v is bool or v is int or v is String:
		return v
	if v is float:
		return snappedf(v, QUANT_STEP)
	if v is Vector2:
		return {"x": snappedf(v.x, QUANT_STEP), "y": snappedf(v.y, QUANT_STEP)}
	if v is Vector2i:
		return {"x": v.x, "y": v.y}
	if v is Array:
		var arr_out: Array = []
		for e in v:
			arr_out.append(quantize_value(e))
		return arr_out
	if v is Dictionary:
		var dict_out := {}
		for k in v:
			dict_out[str(k)] = quantize_value(v[k])
		return dict_out
	return v


# ============================== 内部实现 ==============================

static func _ok() -> Dictionary:
	return {"ok": true, "error": ""}


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}


static func _shapes_for_kind(kind: String) -> Array:
	if kind == NODE_PRIMITIVE:
		return PRIMITIVE_SHAPES
	if kind == NODE_BOOLEAN:
		return BOOLEAN_OPS
	return []


func _add_node(id: String, kind: String, shape: String, params: Dictionary) -> Dictionary:
	var msg := _validate_node(id, kind, shape, _nodes)
	if msg != "":
		return _err(msg)
	_nodes[id] = {"id": id, "kind": kind, "shape": shape, "params": quantize_value(params)}
	_order.append(id)
	_parents[id] = []
	_children[id] = []
	return _ok()


static func _validate_node(id: String, kind: String, shape: String, existing: Dictionary) -> String:
	if id.strip_edges() == "":
		return "节点 id 不能为空"
	if existing.has(id):
		return "节点 id 重复：%s" % id
	var shapes := _shapes_for_kind(kind)
	if shapes.is_empty():
		return "未知节点类型 \"%s\"（可用：%s / %s）" % [kind, NODE_PRIMITIVE, NODE_BOOLEAN]
	if not shapes.has(shape):
		return "未知的 %s 形状 \"%s\"（可用：%s）" % [kind, shape, str(shapes)]
	return ""


## 已确定无环？若无环返回 []，否则返回环上节点（环绕方向：cyc[0] → ... → cyc[0]）。
## 迭代式 DFS（显式帧）：形状链可能很长，不赌递归深度。
static func _find_cycle(children: Dictionary, order: Array) -> Array:
	var color := {}   # 缺省 0 = 未访问；1 = 在栈上；2 = 已完成
	for start_v in order:
		var start := str(start_v)
		if int(color.get(start, 0)) != 0:
			continue
		var stack: Array = [start]
		var frames: Array = [{"id": start, "next": 0}]
		color[start] = 1
		while not frames.is_empty():
			var frame: Dictionary = frames[frames.size() - 1]
			var cur: String = frame["id"]
			var kids: Array = children.get(cur, [])
			var idx: int = int(frame["next"])
			if idx >= kids.size():
				frames.pop_back()
				stack.pop_back()
				color[cur] = 2
				continue
			frame["next"] = idx + 1
			var nxt := str(kids[idx])
			var c := int(color.get(nxt, 0))
			if c == 1:
				var at := stack.find(nxt)
				var cyc: Array = []
				for i in range(maxi(at, 0), stack.size()):
					cyc.append(stack[i])
				return cyc
			if c == 0:
				color[nxt] = 1
				stack.append(nxt)
				frames.append({"id": nxt, "next": 0})
	return []


static func _cycle_text(cycle: Array) -> String:
	var parts := PackedStringArray()
	for id in cycle:
		parts.append(str(id))
	if parts.size() > 0:
		parts.append(parts[0])
	return " → ".join(parts)


## 就绪队列按**插入顺序**插入（同一入度的稳定规则）。
func _insert_by_order(arr: Array, id: String) -> void:
	var oi := _order_index(id)
	var pos := arr.size()
	for i in arr.size():
		if _order_index(str(arr[i])) > oi:
			pos = i
			break
	arr.insert(pos, id)


func _order_index(id: String) -> int:
	return _order.find(id)


func _remove_edge_raw(parent_id: String, child_id: String) -> void:
	(_children[parent_id] as Array).erase(child_id)
	(_parents[child_id] as Array).erase(parent_id)
	var kept: Array = []
	for e in _edges:
		if not (e["from"] == parent_id and e["to"] == child_id):
			kept.append(e)
	_edges = kept


func _remove_node_raw(id: String) -> void:
	if not _nodes.has(id):
		return
	for p in (_parents.get(id, []) as Array).duplicate():
		(_children[p] as Array).erase(id)
	for c in (_children.get(id, []) as Array).duplicate():
		(_parents[c] as Array).erase(id)
	var kept: Array = []
	for e in _edges:
		if e["from"] != id and e["to"] != id:
			kept.append(e)
	_edges = kept
	_nodes.erase(id)
	_parents.erase(id)
	_children.erase(id)
	_order.erase(id)
