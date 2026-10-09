class_name TopologyModel
extends RefCounted

## 拓扑模型：把“邻接表是否合法”“它该怎么呈现给玩家”收口到同一处。
##
## 本文件只做三件事：
##   1. 解析并审计 topology（两种既有形式都支持）；
##   2. 把外部/编辑器产出的拓扑整理成**对称、无自环、无重复、无盘外**的规范形式；
##   3. 读写视觉元数据（环绕 / 虫洞 / 不可能几何 / 折叠）。
##
## 兼容纪律：不改变任何合法旧关卡的邻接语义。规范形式统一写成
## positions + neighbors，邻居按 (y,x) 升序，与 spec 的 refs="topo" 索引序一致。

const VIEW_PLAIN := ""
const VIEW_WRAP := "wrap"
const VIEW_WORMHOLE := "wormhole"
const VIEW_IMPOSSIBLE := "impossible"
const VIEW_FOLD := "fold"


## {"x":.., "y":..} / [x,y] / Vector2i -> Vector2i；不可解析返回 null。
static func parse_pos(v: Variant) -> Variant:
	if v is Vector2i:
		return v
	if v is Dictionary:
		var d: Dictionary = v
		if d.has("x") and d.has("y"):
			return Vector2i(int(d["x"]), int(d["y"]))
	if v is Array:
		var a: Array = v
		if a.size() >= 2:
			return Vector2i(int(a[0]), int(a[1]))
	return null


## "x,y" / {x,y} / [x,y] -> Vector2i；不可解析返回 null。
static func parse_key(v: Variant) -> Variant:
	if v is Vector2i or v is Dictionary or v is Array:
		return parse_pos(v)
	if v is String:
		var parts := (v as String).split(",")
		if parts.size() == 2:
			return Vector2i(int(parts[0]), int(parts[1]))
	return null


static func key_of(p: Vector2i) -> String:
	return "%d,%d" % [p.x, p.y]


static func _sorted_unique_positions(ps: Array) -> Array:
	var out: Array[Vector2i] = []
	for p: Variant in ps:
		if p is Vector2i and not out.has(p):
			out.append(p)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	return out


## 审计任意 topology。返回：
## {ok, errors, warnings, positions, edges, self_loop, dangling, duplicate, asymmetric}
## edges = [[Vector2i a, Vector2i b], ...] ——**重建邻接表用的方向对**：
##   形式 2（neighbors）按作者写的方向收；形式 1（adjacency）的边本身无向 ⇒ 两个方向都收。
## 调用方（canonicalize）只按 edges 重建，所以 edges 必须自带足够信息，**不能靠猜**。
##
## 分级（2026-10-09 定稿）：
##   盘外邻接 / 重复邻接 / 单向邻接 = **error**：它们会让「作者以为的图」与「引擎用的图」不一致。
##   自环（含自身）= **warning**：这是 `WrapTopology.build(..., include_self=true)` 的既有玩法
##   （test_wrap_topology.gd:test_include_self_adds_the_cell_itself）。判成 error 的话，
##   含自身的关卡会在 LevelLoader 被拒——HEAD 期没有拓扑硬闸门，那是**收窄**，不是修复。
static func validate(topo: Dictionary, allow_negative := false) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var positions: Array[Vector2i] = []
	var pos_set: Dictionary = {}
	var raw_positions: Variant = topo.get("positions", [])
	if not (raw_positions is Array) or (raw_positions as Array).is_empty():
		errors.append("拓扑没有 positions：无法建立棋盘")
	else:
		for raw: Variant in raw_positions:
			var p_v: Variant = parse_pos(raw)
			if p_v == null:
				errors.append("positions 里有无法解析的条目：%s" % str(raw))
				continue
			var p: Vector2i = p_v
			if not allow_negative and (p.x < 0 or p.y < 0):
				errors.append("positions 含负坐标 (%d,%d)：CP-SAT 索引会越界" % [p.x, p.y])
				continue
			if pos_set.has(p):
				errors.append("positions 重复 (%d,%d)" % [p.x, p.y])
				continue
			pos_set[p] = true
			positions.append(p)

	var directed: Dictionary = {}     # key -> {key: true}
	var self_loop := 0
	var dangling := 0
	var duplicate := 0
	var edge_list: Array = []
	var has_edges := false

	if topo.has("neighbors"):
		var nb_v: Variant = topo["neighbors"]
		if not (nb_v is Dictionary):
			errors.append("neighbors 不是字典")
		else:
			has_edges = true
			var nb: Dictionary = nb_v
			for raw_src: Variant in nb.keys():
				var av: Variant = parse_key(raw_src)
				if av == null:
					errors.append("neighbors 的键无法解析：%s" % str(raw_src))
					continue
				var a: Vector2i = av
				if not pos_set.has(a):
					errors.append("neighbors 的源格不在 positions：%s" % str(raw_src))
					continue
				var lst_v: Variant = nb[raw_src]
				if not (lst_v is Array):
					errors.append("neighbors[%s] 不是数组" % str(raw_src))
					continue
				if not directed.has(a):
					directed[a] = {}
				for raw_dst: Variant in (lst_v as Array):
					var bv: Variant = parse_key(raw_dst)
					if bv == null:
						errors.append("neighbors[%s] 有无法解析的邻居：%s" % [str(raw_src), str(raw_dst)])
						continue
					var b: Vector2i = bv
					if not pos_set.has(b):
						dangling += 1
						continue
					var m: Dictionary = directed[a]
					if m.has(b):
						duplicate += 1
						continue
					m[b] = true
					if a == b:
						# 「含自身」：自环必须**原样收进 edge_list**，否则 canonicalize 会把它洗掉，
						# 而 WrapTopology 的 include_self 正是靠它表达。
						self_loop += 1
					edge_list.append([a, b])
	elif topo.has("adjacency"):
		var adj_v: Variant = topo["adjacency"]
		if not (adj_v is Array):
			errors.append("adjacency 不是数组")
		else:
			has_edges = true
			for e_v: Variant in (adj_v as Array):
				if not (e_v is Dictionary):
					errors.append("adjacency 有非字典边")
					continue
				var e: Dictionary = e_v
				var av2: Variant = parse_pos(e.get("a", null))
				var bv2: Variant = parse_pos(e.get("b", null))
				if av2 == null or bv2 == null:
					errors.append("adjacency 的边缺 a/b 坐标")
					continue
				var a2: Vector2i = av2
				var b2: Vector2i = bv2
				if not pos_set.has(a2) or not pos_set.has(b2):
					dangling += 1
					continue
				if not directed.has(a2):
					directed[a2] = {}
				if not directed.has(b2):
					directed[b2] = {}
				if (directed[a2] as Dictionary).has(b2):
					duplicate += 1
					continue
				(directed[a2] as Dictionary)[b2] = true
				if a2 == b2:
					(directed[b2] as Dictionary)[a2] = true
					self_loop += 1
					edge_list.append([a2, b2])
					continue
				(directed[b2] as Dictionary)[a2] = true
				# 形式 1 是无向边表 ⇒ 两个方向都进 edges（重建时不必再猜）。
				edge_list.append([a2, b2])
				edge_list.append([b2, a2])
	if positions.size() > 1 and not has_edges:
		warnings.append("拓扑有多个格但没有邻接表：每格都会是孤岛")
	if self_loop > 0:
		# 只提醒，不阻断（理由见函数头：含自身是受支持的玩法，不是坏数据）。
		warnings.append("存在自环 %d 处（含自身计数：该格出现在自己的邻居表里）" % self_loop)
	if dangling > 0:
		errors.append("有 %d 条邻接指向盘外格" % dangling)
	if duplicate > 0:
		errors.append("存在重复邻接 %d 处" % duplicate)

	var asymmetric := 0
	for a_key: Variant in directed.keys():
		var a3: Vector2i = a_key
		var m3: Dictionary = directed[a_key]
		for b_key: Variant in m3.keys():
			var b3: Vector2i = b_key
			var rev: Dictionary = directed.get(b3, {})
			if not rev.has(a3):
				asymmetric += 1
	if asymmetric > 0:
		errors.append("邻接不对称 %d 处（a 在 b 的邻居里，但 b 不在 a 的邻居里）" % asymmetric)

	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"positions": positions,
		"edges": edge_list,
		"self_loop": self_loop,
		"dangling": dangling,
		"duplicate": duplicate,
		"asymmetric": asymmetric,
	}


## 规范形式：positions + neighbors（去重、丢盘外、按 (y,x) 排序）。
##
## 【兼容纪律 · 2026-10-09】本函数**只搬运，不发明**邻接语义：
##   · 形式 2（neighbors）：逐格照抄作者写的边，**不自动补双向**。单向边是坏数据，交给
##     validate / 编辑器审计**报错**暴露，绝不在加载时静默修好——静默补边会把作者的笔误
##     变成一张「看起来没问题、但和作者写的不是同一张」的盘（本仓的「报错不静默」纪律）。
##   · 形式 1（adjacency）：边表无向，validate 已把两个方向都收进 edges，这里照建。
##   · 自环（含自身）照抄；盘外邻接丢弃（与 HEAD 的 setup_from_topo 行为一致）。
##   · 邻居按 (y,x) 升序：与 WrapTopology / 声明式规格 refs="topo" 的索引序同口径。
## 不走 validate 的报错路径，便于 Board 直接加载旧数据；需要硬闸门时调用方先调 validate。
static func canonicalize(topo: Dictionary) -> Dictionary:
	# 规范化允许负坐标：AdjacencyGrid.normalized / 旧六边形族会在内存里用负坐标，
	# 真正的硬闸门由 LevelLoader 的默认 validate(false) 承担。
	var audit := validate(topo, true)
	var positions: Array[Vector2i] = []
	for p_v: Variant in audit["positions"]:
		positions.append(p_v)
	var pos_set: Dictionary = {}
	for p in positions:
		pos_set[p] = true
	var neighbors: Dictionary = {}
	for p in positions:
		neighbors[key_of(p)] = []
	for edge_v: Variant in audit["edges"]:
		var edge: Array = edge_v
		var a: Vector2i = edge[0]
		var b: Vector2i = edge[1]
		if not pos_set.has(a) or not pos_set.has(b):
			continue
		# 只按 edges 写：形式 2 的 edges 只有作者写过的方向（单向边就这么留着，交给
		# validate 报错）；形式 1 的 edges 已被 validate 展开成双向。这里**绝不**再补反向，
		# 否则形式 2 的单向笔误会被静默修好，编辑器也就不用报错了。
		var la: Array = neighbors[key_of(a)]
		if not la.has(key_of(b)):
			la.append(key_of(b))
	_sort_neighbor_lists(neighbors)
	var out: Dictionary = {}
	for k2: Variant in topo.keys():
		if k2 != "neighbors" and k2 != "adjacency":
			out[k2] = topo[k2]
	var pos_out: Array = []
	for p2 in positions:
		pos_out.append({"x": p2.x, "y": p2.y})
	out["positions"] = pos_out
	out["neighbors"] = neighbors
	return out


## 从 editor / view / style 推断呈现种类；显式 view.kind 优先。
static func view_kind(topo: Dictionary) -> String:
	var view_v: Variant = topo.get("view", {})
	if view_v is Dictionary:
		var kind := str((view_v as Dictionary).get("kind", ""))
		if kind != "":
			return kind
	var editor_v: Variant = topo.get("editor", {})
	if editor_v is Dictionary and bool((editor_v as Dictionary).get("wrap", false)):
		return VIEW_WRAP
	if not portal_pairs(topo).is_empty():
		return VIEW_WORMHOLE
	if str(topo.get("style", "")) == "iso_cubes":
		return VIEW_IMPOSSIBLE
	if topo.has("fold"):
		return VIEW_FOLD
	return VIEW_PLAIN


## 虫洞对：读取顶层 portals 或 view.portals。返回 [{a:Vector2i,b:Vector2i,id:String}, ...]。
static func portal_pairs(topo: Dictionary) -> Array:
	var raw: Variant = topo.get("portals", null)
	if raw == null:
		var view_v: Variant = topo.get("view", {})
		if view_v is Dictionary:
			raw = (view_v as Dictionary).get("portals", [])
	if not (raw is Array):
		return []
	var out: Array = []
	var seen := {}
	for item_v: Variant in (raw as Array):
		if not (item_v is Dictionary):
			continue
		var item: Dictionary = item_v
		var av: Variant = parse_pos(item.get("a", null))
		var bv: Variant = parse_pos(item.get("b", null))
		if av == null or bv == null:
			continue
		var a: Vector2i = av
		var b: Vector2i = bv
		if a == b:
			continue
		var pair_key := "%s|%s" % [key_of(a), key_of(b)]
		var rev_key := "%s|%s" % [key_of(b), key_of(a)]
		if seen.has(pair_key) or seen.has(rev_key):
			continue
		seen[pair_key] = true
		out.append({"a": a, "b": b, "id": str(item.get("id", ""))})
	return out


## 把虫洞对写入邻接表，保证双向边存在，并写 view.kind=wormhole。
## 返回 {ok, topology, errors}。
static func attach_portals(topo: Dictionary, portals: Array) -> Dictionary:
	var out := canonicalize(topo)
	var pos_set := {}
	for p_v: Variant in out.get("positions", []):
		var pv: Variant = parse_pos(p_v)
		if pv != null:
			pos_set[pv] = true
	var clean: Array = []
	var errors: Array[String] = []
	for item_v: Variant in portals:
		if not (item_v is Dictionary):
			errors.append("虫洞条目不是字典")
			continue
		var item: Dictionary = item_v
		var av: Variant = parse_pos(item.get("a", null))
		var bv: Variant = parse_pos(item.get("b", null))
		if av == null or bv == null:
			errors.append("虫洞两端缺坐标")
			continue
		var a: Vector2i = av
		var b: Vector2i = bv
		if not pos_set.has(a) or not pos_set.has(b):
			errors.append("虫洞端点不在盘上：%s -> %s" % [str(a), str(b)])
			continue
		if a == b:
			errors.append("虫洞两端不能是同一格：%s" % str(a))
			continue
		_add_edge(out["neighbors"], a, b)
		clean.append({"a": {"x": a.x, "y": a.y}, "b": {"x": b.x, "y": b.y}, "id": str(item.get("id", ""))})
	out["portals"] = clean
	var view: Dictionary = out.get("view", {}) if out.get("view", {}) is Dictionary else {}
	view["kind"] = VIEW_WORMHOLE
	out["view"] = view
	return {"ok": errors.is_empty(), "topology": out, "errors": errors}


## 静态折叠：把「哪两格叠在一起」写进邻接表，并挂上折痕元数据（渲染用）。
## 返回 {ok, topology, errors, pairs, overhang, floating} —— 与 attach_portals 同形。
##
## 【语义】远侧（索引 ≥ at）沿折痕镜像翻到近侧：镜像位上有格 ⇒ 两层贴合 ⇒ 互为邻居。
## 翻过头（镜像索引 < 0，折角翘出盘外）或对面被挖空 ⇒ **不加边**，只记进 overhang/floating
## 供作者自检（挖洞盘天然会有悬空格，故它们不是错误）。非法参数才是错误：
## ok=false 时邻接表**一格都不改**（宁可整块拒绝，也不留半张折过的盘）。
static func attach_fold(topo: Dictionary, fold: Dictionary) -> Dictionary:
	var out := canonicalize(topo)
	var positions: Array[Vector2i] = []
	for p_v: Variant in (out.get("positions", []) as Array):
		var pv: Variant = parse_pos(p_v)
		if pv != null:
			positions.append(pv)
	var rep := FoldModel.audit(fold, positions)
	if not bool(rep["ok"]):
		return {"ok": false, "topology": out, "errors": rep["errors"],
				"pairs": [], "overhang": [], "floating": []}
	var touched: Array = []
	for pr_v: Variant in (rep["pairs"] as Array):
		var pr: Dictionary = pr_v
		var a: Vector2i = pr["a"]
		var b: Vector2i = pr["b"]
		_add_edge(out["neighbors"], a, b)
		touched.append(key_of(a))
		touched.append(key_of(b))
	_sort_neighbor_lists(out["neighbors"], touched)
	var norm := FoldModel.normalize(fold, positions)
	out["fold"] = norm["fold"]
	var view: Dictionary = out.get("view", {}) if out.get("view", {}) is Dictionary else {}
	view["kind"] = VIEW_FOLD
	out["view"] = view
	return {"ok": true, "topology": out, "errors": [],
			"pairs": rep["pairs"], "overhang": rep["overhang"],
			"uncovered": rep["uncovered"], "floating": rep["floating"]}


static func fold_meta(topo: Dictionary) -> Dictionary:
	var v: Variant = topo.get("fold", {})
	return _norm_fold_decl(v) if v is Dictionary else {}


## 折痕声明：读**顶层 fold** 或 **view.fold**（生成器写的是后者）。
## 返回 {axis, at}（读不到 / 空 ⇒ 空字典）。与 `portal_pairs` 同形：加载侧与呈现侧都用它，
## 免得两处各自解析、口径漂移。
static func fold_decl(topo: Dictionary) -> Dictionary:
	var out := fold_meta(topo)
	if not out.is_empty():
		return out
	var view_v: Variant = topo.get("view", {})
	if view_v is Dictionary:
		var fv: Variant = (view_v as Dictionary).get("fold", {})
		if fv is Dictionary and not (fv as Dictionary).is_empty():
			return _norm_fold_decl(fv)
	return {}


## 折痕声明的 at 统一成 int：JSON 落盘/读回会把整数读成浮点（3 -> 3.0），
## 不归一化就会在「打开官方关 -> 另存」时让折痕字段类型静默漂移。
static func _norm_fold_decl(v: Variant) -> Dictionary:
	if not (v is Dictionary):
		return {}
	var out: Dictionary = (v as Dictionary).duplicate(true)
	var at_v: Variant = out.get("at", null)
	if at_v is int or at_v is float:
		out["at"] = int(at_v)
	return out


## AdjacencyGrid 用的呈现元数据：view + 推断信息，供 BoardView 读取。
static func view_meta(topo: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var view_v: Variant = topo.get("view", {})
	if view_v is Dictionary:
		out = (view_v as Dictionary).duplicate(true)
	var kind := view_kind(topo)
	if kind != "":
		out["kind"] = kind
	if kind == VIEW_WRAP:
		var editor_v: Variant = topo.get("editor", {})
		var ed: Dictionary = editor_v if editor_v is Dictionary else {}
		out["wrap"] = {"horizontal": bool(ed.get("wrap", true)), "vertical": bool(ed.get("wrap", true))}
	if kind == VIEW_WORMHOLE:
		out["portals"] = portal_pairs(topo)
	# ⚠ 必须走 fold_decl（顶层 **或** view.fold）：生成器落盘的是 view.fold，
	# 若这里用 fold_meta（只读顶层）就会把读回来的声明**覆盖成空** —— 呈现层于是
	# 看不到折痕（"能生成、读不回"，正是本仓最恨的那类 bug）。
	if kind == VIEW_FOLD or topo.has("fold"):
		var fd := fold_decl(topo)
		if not fd.is_empty():
			out["fold"] = fd
	return out


## 呈现元数据 → **JSON 安全副本**（写盘路径必须过这里）。
## 为什么需要：`JSON.stringify` 不认识 Vector2i，会把它变成 "(0, 0)" 这种字符串
## ⇒ 落盘再读回时 parse_pos 解不出来、虫洞/端点被**静默丢掉**（正是本仓最恨的那类 bug）。
## 规则：Vector2i → {x,y}；Dictionary / Array 递归；其余原样。
static func json_safe_view(meta: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in meta.keys():
		var v: Variant = meta[k]
		if v is Vector2i:
			var p: Vector2i = v
			out[k] = {"x": p.x, "y": p.y}
		elif v is Dictionary:
			out[k] = json_safe_view(v as Dictionary)
		elif v is Array:
			out[k] = _json_safe_array(v as Array)
		else:
			out[k] = v
	return out


static func _json_safe_array(src: Array) -> Array:
	var out: Array = []
	for it: Variant in src:
		if it is Vector2i:
			var p: Vector2i = it
			out.append({"x": p.x, "y": p.y})
		elif it is Dictionary:
			out.append(json_safe_view(it as Dictionary))
		elif it is Array:
			out.append(_json_safe_array(it as Array))
		else:
			out.append(it)
	return out


## 邻居列表的规范序：按 (y, x) 升序 —— 与声明式规格 refs=「topo」的索引序同口径。
## 单一事实源：canonicalize 与 attach_fold 都调它（attach_portals 是**既有数据**路径，
## 它的追加序原样保留，免得重写既有虫洞关卡的落盘 diff）。
## only_keys 非空 ⇒ 只排这几个键（加完少数几条边后只整理动过的行）。
static func _sort_neighbor_lists(neighbors: Dictionary, only_keys: Array = []) -> void:
	var keys: Array = only_keys if not only_keys.is_empty() else neighbors.keys()
	for k: Variant in keys:
		if not neighbors.has(k):
			continue
		var list: Array = neighbors[k]
		list.sort_custom(func(x: String, y: String) -> bool:
			var px := parse_key(x) as Vector2i
			var py := parse_key(y) as Vector2i
			if px.y != py.y:
				return px.y < py.y
			return px.x < py.x)


static func _add_edge(neighbors: Dictionary, a: Vector2i, b: Vector2i) -> void:
	var ka := key_of(a)
	var kb := key_of(b)
	if not neighbors.has(ka):
		neighbors[ka] = []
	if not neighbors.has(kb):
		neighbors[kb] = []
	var la: Array = neighbors[ka]
	var lb: Array = neighbors[kb]
	if not la.has(kb):
		la.append(kb)
	if not lb.has(ka):
		lb.append(ka)
	_sort_neighbor_list(la)
	_sort_neighbor_list(lb)


static func _sort_neighbor_list(list: Array) -> void:
	list.sort_custom(func(x: Variant, y: Variant) -> bool:
		var px := parse_key(x) as Vector2i
		var py := parse_key(y) as Vector2i
		if px.y != py.y:
			return px.y < py.y
		return px.x < py.x)
