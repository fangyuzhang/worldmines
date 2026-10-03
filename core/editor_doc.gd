class_name EditorDoc
extends RefCounted

## 变体编辑器文档模型（编辑器 P1 内核，2026-10-01）。
##
## 【单一真源】真源只有三样：**雷位、邻域（wrap/dirs/include_self）、规则**。
## 密度、总格数、线索值、初始翻开集合全是**派生量**——派生量不落盘，避免双真源
##（本仓在显示设置上吃过这个亏，见 `ui/settings_manager.gd` 的 A10 记录）。
##
## 【JSON 双射】`to_level_json()` 的产物 `Board.load_level` 能直接吃，这就是"保存后再加载
## 完整还原"的机器可验证版本；反过来 `load_from()` 把关卡 JSON 读回本对象。
## 不认识的字段一律进 `passthrough` 原样带回——**绝不静默丢数据**（含遮蔽区间等本编辑器
## 不编辑、但可能被别人写过的字段）。
##
## 【与运行期同口径】`preview_clues()` 刻意与 `core/board.gd:_compute_clues` 同构：
## 异形/环绕盘**优先问规则自己的 `compute_clue_topo`**，没有该方法才退回"拓扑邻域计数"。
## 这条纪律是本仓踩过的坑（`core/board.gd:276-281` 的注释）：不同构就会出现
## "编辑器显示 4、玩家看到 2"的分叉。
##
## 【坐标约定】对外（JSON）用 `{r, c}`，内部用 `Vector2i(c, r)`——与 `Board.load_level`
##（`Vector2i(m["c"], m["r"])`）和 `RuleCpSat`（`[r,c] → Vector2i(c,r)`）保持同一套换算。
## 本文件所有内部函数一律吃 Vector2i(c, r)，**换算只发生在 to/from JSON 两处**。

const SCHEMA_ID := "editor/v1"
const MAX_CELLS := WrapTopology.MAX_CELLS

var title := "未命名变体"
var rows := 9
var cols := 9

# —— 邻域 ——
var wrap := false
var dirs: Array[Vector2i] = []        # 空 = 默认 Moore 8 邻
var include_self := false

# —— 盘面 ——
var mines: Array[Vector2i] = []       # 真源：雷位
var obstacles: Array[Vector2i] = []   # 障碍 = "格不存在"（洞）——由拓扑的 positions 缺项表达
var revealed: Dictionary = {}         # Vector2i -> null：初始翻开集合（值由预览重算）

# —— 规则 ——
var rule_spec: Dictionary = {}        # spec v1 原文；空 = 用 clue_rule_id 或内置 classic
var clue_rule_id := ""                # 空 ⇒ classic
var global_rule_ids: Array[String] = []

## 关卡声明的总雷数（JSON 的 `total_mines`）。-1 = 未声明（导出时写实际雷位数）。
## 为什么必须保留它而不是"总是写实际值"：导入一份"声明雷数 ≠ 实际雷位"的关卡时，
## **静默修正等于帮用户把错误藏起来**——而"存在逻辑矛盾"正是验证器要给出的结论之一
##（见 `core/editor_verify.gd`）。谁的问题谁背：模型如实保留，validate 报错，验证器给矛盾。
var declared_total_mines := -1

# —— 预留扩展（只声明、不接玩法；YAGNI：半成品语义不许污染核心） ——
var warp_points: Array[Vector2i] = []
var regions: Array = []

## 外部拓扑（六边形 / 三角 / ASCII 轮廓等，由 `ShapeGenerator` 生成、不带 `editor` 元数据的那种）。
## 【为什么必须单独存一份】本模型原先的做法是：载入后只读 `editor` 元数据（dirs/wrap/含自身），
## 再"按这些参数重新推导" topology。对**外部盘型**这会把它静默换成方阵——
## 一份六边形关卡被编辑器打开再保存，盘型就没了，且不可逆。所以这里原样留存、`topology()` 直返。
var foreign_topology: Dictionary = {}

## 形状族（`""` = 方阵）。非空时棋盘由 `ShapeGenerator.to_adjacency_grid` 生成
## （六边形 / 三角 / 截角 / 环 / ASCII 轮廓…共 9 族），此时「环绕边界 / 邻域偏移 / 含自身」
## 这些**方形邻域控件不适用**——与"载入外部拓扑"同理，UI 会禁用它们。
## `shape_params` 直接透传给 `ShapeGenerator`（如 hex: `{"size": 4}`；tri_grid: `{"cols": 6, "rows": 4}`）。
var shape_kind := ""
var shape_params: Dictionary = {}

# —— 缓存（键 = struct_signature()，见其注释；内容变则签名变，缓存自动失效）——
var _topo_cache: Dictionary = {}
var _topo_sig := ""
var _grid_cache: GridInterface = null
var _grid_sig := ""
var _audit_sig := ""
var _audit_errors: Array = []
var _audit_warnings: Array = []

# —— 无损往返 ——
var passthrough: Dictionary = {}       # 本模型不认识的关卡字段，导出时原样写回
var _revealed_extras: Array = []       # 带 interval（遮蔽区间）的 revealed 条目：不编辑，原样写回
var _revealed_merge: Dictionary = {}   # Vector2i -> 带附加键的 revealed 原文：导出时合并回同一条


## 把 `rows/cols` 同步成形状盘的包围盒（UI 选完形状/尺寸后调用）。
## 为什么必须同步：关卡 JSON 的 `size` 与拓扑必须自洽——`LevelValidator` 按 size 校验雷位，
## 渲染与 CP-SAT 也都按 size/包围盒走；不同步就会出现"雷位全越界"这类假错误。
func sync_size_to_shape() -> void:
	if shape_kind == "":
		return
	var g: AdjacencyGrid = ShapeGenerator.to_adjacency_grid(shape_kind, shape_params)
	if g == null:
		return
	var s := AdjacencyGrid.normalized(g).size()
	rows = maxi(s.y, 1)
	cols = maxi(s.x, 1)


## 把任意 GridInterface 导出成邻接表（形式 2：positions + neighbors）——
## 与本仓"落盘用形式 1、读取优先形式 2"的约定一致（`setup_from_topo` 优先读 neighbors）。
static func _topology_dict_of(g: GridInterface) -> Dictionary:
	var positions: Array = []
	var neighbors := {}
	for p in g.all_positions():
		positions.append({"x": p.x, "y": p.y})
		var lst: Array = []
		for nb in g.get_neighbors(p):
			lst.append("%d,%d" % [nb.x, nb.y])
		neighbors["%d,%d" % [p.x, p.y]] = lst
	var out := {"positions": positions, "neighbors": neighbors, "style": "custom"}
	if g is AdjacencyGrid:
		var ag := g as AdjacencyGrid
		if ag.style != "":
			out["style"] = ag.style
		if not ag.style_params.is_empty():
			out["params"] = ag.style_params
	return out


func _init(p_rows: int = 9, p_cols: int = 9) -> void:
	rows = p_rows
	cols = p_cols


# ==================== 派生量 ====================

func cell_count() -> int:
	return rows * cols - obstacles.size()


func mine_count() -> int:
	return mines.size()


## 求解/验证用的总雷数：优先**声明值**（矛盾往往就在"声明 vs 实际"之间），否则实际雷位数。
func total_mines_for_solving() -> int:
	return declared_total_mines if declared_total_mines >= 0 else mines.size()


func density() -> float:
	var n := cell_count()
	if n <= 0:
		return 0.0
	return float(mines.size()) / float(n)


## 当前生效的规则 id：spec 优先（其 id），其次显式 clue_rule_id，最后内置 classic。
func rule_id_effective() -> String:
	var base := ""
	if not rule_spec.is_empty():
		base = str(rule_spec.get("id", ""))
	if base.is_empty():
		base = clue_rule_id
	if base.is_empty():
		base = "classic"
	# ⚠ **本返回值会被当「线索规则 id」拿去算关卡**（`_forge_opts` 填 `clue_rule_id`）⇒ 只能是
	# **能被 `RuleRegistry` 解析的单个规则 id**。
	# 【审查 #1 的血案】上一版我把全局规则也拼进来（`classic+pf`）⇒ `RuleRegistry.resolve()` 为空 ⇒
	# 带布局规则的变体**批量生成 0 关**，界面还错报"太难命中"。要区分全局规则的是**身份**
	# （目录/包 id），那是 `level_editor._forge_mode()` 的活，不在这里。
	return base


## 解析规则对象：spec 原文优先（**不注册**，避免编辑器打字过程污染全局注册表），
## 其次查全局注册表，最后内置 classic。返回 null = 解析失败（由 validate 报错）。
func rule_object() -> Object:
	if not rule_spec.is_empty():
		var rid := str(rule_spec.get("id", ""))
		var r := SpecRulePlugin.from_json(JSON.stringify(rule_spec))
		if bool(r.get("ok", false)):
			return r.get("rule", null)
		# 【2026-10-01 由编辑器测试抓到并修掉的真 bug】`SpecSchema.validate` 有一条
		# "规格 id 必须全局唯一"（`core/spec_schema.gd:122-124`）⇒ 用户一按「试玩」把规则注册进
		# 全局表，`from_json` 就会**因为 id 已被注册而拒收**，表现为"一按试玩，预览立刻报规则未解析"。
		# 唯一的可接受失败就是这一种（同名 id、同源规格）⇒ 用注册实例兜底继续预览。
		# 其余失败（标题缺失、偏移越界…）必须如实返回 null 让 UI 报错，
		# **绝不**用注册表里的别的规则顶替（那会把"规格写错了"伪装成"能跑"）。
		var msg := _join(r.get("errors", []))
		if rid != "" and msg.find("已被注册") != -1:
			return RuleRegistry.default().resolve(StringName(rid))
		return null
	return RuleRegistry.default().resolve(StringName(rule_id_effective()))


# ==================== 邻域 / 棋盘 ====================

## 产出 topology dict（`{}` = 默认矩形盘，走 RectGrid，与今天逐位一致）。
## 有障碍时必须强制产出邻接表：RectGrid 没有"格不存在"的表示法。
## 结构签名：行/列/邻域/障碍/外部拓扑的**廉价内容摘要**（O(障碍数+偏移数) 次整数运算）。
##
## 【为什么必须有它】实测（64x64 环绕盘 / 400 雷，2026-10-02 探针）：`WrapTopology.build` 48.9 ms、
## `AdjacencyGrid.setup_from_topo` 91.5 ms（它要逐条 `String.split(",")` 解析约 32k 个邻居键），
## 而 `validate()`/`preview_clues()`/`grid()` 各自都会再建一遍 ⇒ **画一格 ≈ 610 ms**（拖动画笔等于卡死）。
## 有了签名就能安全缓存这三样：内容变 ⇒ 签名变 ⇒ 缓存自动失效。
## 选"内容摘要"而不是"要求调用方记得 invalidate"：后者漏一次就是幽灵 bug，本仓吃过这种亏。
func struct_signature() -> String:
	var h: int = 1469598103934665603
	h = (h ^ rows) * 1099511628211
	h = (h ^ cols) * 1099511628211
	h = (h ^ (1 if wrap else 0)) * 1099511628211
	h = (h ^ (1 if include_self else 0)) * 1099511628211
	h = (h ^ dirs.size()) * 1099511628211
	for d in dirs:
		h = (h ^ (d.x * 31 + d.y)) * 1099511628211
	h = (h ^ obstacles.size()) * 1099511628211
	for o in obstacles:
		h = (h ^ (o.x * 31 + o.y)) * 1099511628211
	h = (h ^ shape_kind.hash()) * 1099511628211
	h = (h ^ JSON.stringify(shape_params).hash()) * 1099511628211
	h = (h ^ foreign_topology.size()) * 1099511628211
	for p in foreign_topology.get("positions", []):
		var d2: Dictionary = p
		h = (h ^ (int(d2["x"]) * 31 + int(d2["y"]))) * 1099511628211
	h &= 0x7FFFFFFFFFFFFFFF   # 保持正数（GDScript int 溢出会回卷，掩码后键串不带负号）
	return "%dx%d:%d" % [rows, cols, h]


func topology() -> Dictionary:
	if rows < 1 or cols < 1:
		return {}
	var sig := struct_signature()
	if sig == _topo_sig:
		return _topo_cache
	_topo_cache = _build_topology()
	_topo_sig = sig
	return _topo_cache


func _build_topology() -> Dictionary:
	if shape_kind != "":
		# 形状族：借 `ShapeGenerator` 的 9 族实现（六边形/三角/截角/环/轮廓…），不自己造
		var g: AdjacencyGrid = ShapeGenerator.to_adjacency_grid(shape_kind, shape_params)
		if g == null:
			return {}
		# ⚠ 必须归一到非负坐标：六边形等以中心为原点 ⇒ 负坐标会让 CP-SAT 索引越界、
		# 并让审计报"存在负坐标"（`AdjacencyGrid.normalized` 就是为这件事存在的）。
		var norm := AdjacencyGrid.normalized(g)
		var shaped := _topology_dict_of(norm)
		if obstacles.is_empty():
			return shaped
		return _carve_holes(shaped, obstacles)
	if not foreign_topology.is_empty():
		# 外部盘型：原样返回（障碍只做"再挖一次洞"，幂等）。**绝不**按 dirs/wrap 重建。
		if obstacles.is_empty():
			return foreign_topology
		return _carve_holes(foreign_topology, obstacles)
	var r := WrapTopology.build(rows, cols, dirs, include_self, wrap, not obstacles.is_empty())
	if not bool(r["ok"]):
		return {}
	var topo: Dictionary = r["topology"]
	if obstacles.is_empty() or topo.is_empty():
		return topo
	return _carve_holes(topo, obstacles)


## 棋盘对象（矩形盘 RectGrid / 其余 AdjacencyGrid），供预览与验证共用。
## 带缓存：`setup_from_topo` 在 64x64 环绕盘上实测 91.5 ms，不能每次预览都重建。
func grid() -> GridInterface:
	var sig := struct_signature()
	if sig == _grid_sig and _grid_cache != null:
		return _grid_cache
	var topo := topology()
	if not topo.is_empty():
		var ag := AdjacencyGrid.new()
		ag.setup_from_topo(topo)
		_grid_cache = ag
	else:
		var rg := RectGrid.new()
		rg.setup(rows, cols)
		_grid_cache = rg
	_grid_sig = sig
	return _grid_cache


func mine_set() -> Dictionary:
	var out := {}
	for m in mines:
		out[m] = true
	return out


## 从拓扑里挖掉"不存在的格"（障碍）。
##
## 【2026-10-02 由真实关卡抓到的 bug，勿改回单形态】拓扑有**两种等价形式**：
## 形式 1 = `positions + adjacency`（边表，`ShapeGenerator` 产出、`mod_api` 的 board.json 约定），
## 形式 2 = `positions + neighbors`（`setup_from_topo` 优先读的那个）。
## 本函数最初只处理形式 2：对形式 1 的盘，`neighbors` 缺失 ⇒ 输出一张**空的 neighbors** ⇒
## `setup_from_topo` 优先读 neighbors ⇒ **整盘邻接全丢**（实测：`levels/ani_butterfly.json`
## 158 个格全部"没有任何邻居"），而且这份坏拓扑还会被 `to_level_json()` 原样写回去。
## 现在两形态都处理，并把 `style/params/editor` 等未知键**原样保留**。
static func _carve_holes(topo: Dictionary, holes: Array[Vector2i]) -> Dictionary:
	var hole := {}
	for h in holes:
		hole["%d,%d" % [h.x, h.y]] = true
	var out := {}
	for k in topo:
		if k != "positions" and k != "neighbors" and k != "adjacency":
			out[k] = topo[k]
	var positions: Array = []
	for p in topo.get("positions", []):
		var d: Dictionary = p
		if hole.has("%d,%d" % [int(d["x"]), int(d["y"])]):
			continue
		positions.append(d)
	out["positions"] = positions
	if topo.has("neighbors"):
		var nbs_out := {}
		var nbs_in: Variant = topo["neighbors"]
		if nbs_in is Dictionary:
			for key in nbs_in:
				if hole.has(String(key)):
					continue
				var lst: Array = []
				for nk in nbs_in[key]:
					if not hole.has(String(nk)):
						lst.append(nk)
				nbs_out[key] = lst
		out["neighbors"] = nbs_out
	elif topo.has("adjacency"):
		var edges: Array = []
		var adj_in: Variant = topo["adjacency"]
		if adj_in is Array:
			for e in adj_in:
				if not (e is Dictionary):
					continue
				var ed: Dictionary = e
				var ka := _point_key(ed.get("a", {}))
				var kb := _point_key(ed.get("b", {}))
				if hole.has(ka) or hole.has(kb):
					continue
				edges.append(ed)
		out["adjacency"] = edges
	return out


static func _point_key(p: Variant) -> String:
	if p is Dictionary:
		var d: Dictionary = p
		return "%d,%d" % [int(d.get("x", 0)), int(d.get("y", 0))]
	return ""


# ==================== 实时预览 ====================

## 就地计算全盘线索值（编辑器"改一格立刻看到数字"的数据源）。
## 返回 {"ok": bool, "reason": String, "values": {Vector2i: Variant}}。
## 值用 Variant：本仓线索值可以是 int（计数型）或 Array（双值型），不要假设 int。
func preview_clues() -> Dictionary:
	var g := grid()
	var rule := rule_object()
	if rule == null:
		return {"ok": false, "reason": "规则未解析：%s" % rule_id_effective(), "values": {}}
	var ms := mine_set()
	var values := {}
	for pos in g.all_positions():
		# 显式 Variant：`_clue_value_at` 返回 Variant，用 `:=` 会被判「inferred from a Variant」
		# （本仓把该警告当错误 ⇒ 直接编译失败，2026-10-02 被 --check-only 抓到）
		var v: Variant = _clue_value_at(pos, g, ms, rule)
		if v != null:
			values[pos] = v
	return {"ok": true, "reason": "", "values": values}


## 只算**给定格**的线索值（编辑器改一格后只需重算"该格 + 其邻居"）。
## 与 `preview_clues()` 共用 `_clue_value_at` ⇒ 两条路径不可能算出不同的值
##（这一点由 `test_editor_doc.gd::test_preview_cells_matches_full_preview` 钉住）。
func preview_cells(cells: Array[Vector2i]) -> Dictionary:
	var g := grid()
	var rule := rule_object()
	if rule == null:
		return {}
	var ms := mine_set()
	var out := {}
	for pos in cells:
		var v: Variant = _clue_value_at(pos, g, ms, rule)   # 同上：显式 Variant
		if v != null:
			out[pos] = v
	return out


## 单格线索值。返回 null = 该格不携带线索（是雷，或规则声明 applies_to=false）。
## 分派口径与 `core/board.gd:_compute_clues` 同构（异形盘优先问规则的 compute_clue_topo）。
func _clue_value_at(pos: Vector2i, g: GridInterface, ms: Dictionary, rule: Object) -> Variant:
	if ms.has(pos):
		return null
	var size := Vector2i(cols, rows)
	if g is AdjacencyGrid:
		if rule.has_method("compute_clue_topo"):
			return rule.call("compute_clue_topo", ms, pos, g, size)
		return _count_neighbors(ms, g.get_neighbors(pos))
	if not bool(rule.call("applies_to", pos, size)):
		return null
	return rule.call("compute_clue", ms, pos, size)


static func _count_neighbors(ms: Dictionary, nbs: Array) -> int:
	var n := 0
	for p in nbs:
		if ms.has(p):
			n += 1
	return n


## 建议的初始翻开集合：所有"0 值格"及其邻格（经典扫雷的开局观感）。
## 注意：这是**编辑器的建议**，不是平台的泛洪语义——`Board` 的 0 值扩散按规则的
## `zero_safe_neighbors` 判定，两者在"计数型"规则（classic / 拓扑邻域计数）下一致；
## 加权型规则的自定义 0 值语义不在本函数范围内（作者可手工调整 revealed）。
func suggest_reveal() -> Array[Vector2i]:
	var pv := preview_clues()
	var out: Array[Vector2i] = []
	if not bool(pv["ok"]):
		return out
	var values: Dictionary = pv["values"]
	var ms := mine_set()
	var g := grid()
	var seen := {}
	for pos in values:
		var v: Variant = values[pos]
		# 只把**整数 0** 当"空白格"。双值型线索（Array）没有"0 值泛洪"语义，
		# 对它调用 int() 会直接抛错（本仓线索值类型就是 Variant，必须显式判型）。
		if not (v is int) or int(v) != 0:
			continue
		if not seen.has(pos):
			seen[pos] = true
			out.append(pos)
		for nb in g.get_neighbors(pos):
			if ms.has(nb) or seen.has(nb):
				continue
			seen[nb] = true
			out.append(nb)
	return out


# ==================== 校验（错误必须能定位到格） ====================

## 返回 {"ok": bool, "errors": [ {code,text,pos} ], "warnings": [ ... ]}。
## `pos` 为 Vector2i(-1,-1) 表示"与具体格无关"；UI 据此把错误的格高亮出来。
func validate() -> Dictionary:
	var errors: Array = []
	var warnings: Array = []

	# 1) 尺寸 / 邻域（走 WrapTopology 同一套上限与退化判据，避免两处规则不一致）
	if rows < 1 or cols < 1:
		errors.append(_issue("size", "棋盘尺寸非法（%dx%d）" % [rows, cols]))
	elif rows * cols > MAX_CELLS:
		errors.append(_issue("size", "格数 %d 超过上限 %d" % [rows * cols, MAX_CELLS]))
	var built := WrapTopology.build(rows, cols, dirs, include_self, wrap, false)
	if not bool(built["ok"]):
		errors.append(_issue("neighborhood", str(built["reason"])))
	# 偏移有效性：非环绕时"永远够不到"的偏移是作者手误；环绕时"整圈"偏移等价于自身
	for d in dirs:
		if not wrap and absi(d.x) >= cols and absi(d.y) >= rows:
			warnings.append(_issue("offset_dead", "偏移 (%d,%d) 在 %dx%d 的非环绕盘上永远取不到邻居" % [d.x, d.y, cols, rows]))
		if wrap and cols > 0 and rows > 0 and ((d.x % cols) == 0) and ((d.y % rows) == 0) and d != Vector2i.ZERO:
			warnings.append(_issue("offset_identity", "偏移 (%d,%d) 在环绕盘上正好是整圈 ⇒ 等价于自身邻居" % [d.x, d.y]))

	# 1b) 【清单·数据爆炸 B：邻接图规模】单格邻居太多 ⇒ 那格的数字**读不出来**，求解器也扛不住。
	# 形状盘最容易中招：作者写一张"周围 30 多格"的偏移表时，不会意识到自己在造一个没法读的数字。
	# 判据就地按偏移算（与上面两条偏移告警同一套口径：环绕折回去重、排除自身偏移）。
	var neighbor_cap_warn := 30
	var neighbor_cap_block := 80
	var seen_off := {}
	for d in dirs:
		var dx := d.x
		var dy := d.y
		if wrap and cols > 0 and rows > 0:
			dx = ((dx % cols) + cols) % cols
			dy = ((dy % rows) + rows) % rows
		if dx == 0 and dy == 0:
			continue                       # 自身偏移（含环绕后的整圈）不算邻居
		seen_off[Vector2i(dx, dy)] = true
	var deg := seen_off.size() + (1 if include_self else 0)
	if deg > neighbor_cap_block:
		errors.append(_issue("neighbor_huge",
			"单格邻接 %d 格（上限 %d）—— 这一格的数字没法读、求解器也算不动：请减少邻域偏移" % [deg, neighbor_cap_block]))
	elif deg > neighbor_cap_warn:
		warnings.append(_issue("neighbor_many",
			"单格邻接 %d 格（超过 %d 就该警惕）—— 那格的数字会很难读" % [deg, neighbor_cap_warn]))

	# 2) 雷位
	var mseen := {}
	for m in mines:
		if m.x < 0 or m.y < 0 or m.x >= cols or m.y >= rows:
			errors.append(_issue("mine_oob", "雷位越界 (%d,%d)" % [m.x, m.y], m))
			continue
		if mseen.has(m):
			errors.append(_issue("mine_dup", "雷位重复 (%d,%d)" % [m.x, m.y], m))
		mseen[m] = true
		if obstacles.has(m):
			errors.append(_issue("mine_on_obstacle", "雷位落在障碍格上 (%d,%d)" % [m.x, m.y], m))
	if declared_total_mines >= 0 and declared_total_mines != mines.size():
		errors.append(_issue("declared_mismatch",
			"声明的总雷数 %d 与实际雷位 %d 颗不一致（导出按声明值写入 ⇒ 求解必然矛盾）" % [declared_total_mines, mines.size()]))
	if mines.is_empty():
		errors.append(_issue("no_mines", "还没有地雷：至少放 1 颗才能试玩/验证"))
	elif cell_count() > 0 and mines.size() >= cell_count():
		errors.append(_issue("mines_ge_cells", "雷数 %d ≥ 可用格数 %d" % [mines.size(), cell_count()]))
	if not mines.is_empty() and density() > 0.5:
		warnings.append(_issue("density_high", "雷密度 %.0f%% 偏高（>50%%）：这类关卡通常不可推" % (density() * 100.0)))

	# 3) 障碍与初始翻开
	var oseen := {}
	for o in obstacles:
		if o.x < 0 or o.y < 0 or o.x >= cols or o.y >= rows:
			errors.append(_issue("obstacle_oob", "障碍越界 (%d,%d)" % [o.x, o.y], o))
			continue
		if oseen.has(o):
			errors.append(_issue("obstacle_dup", "障碍重复 (%d,%d)" % [o.x, o.y], o))
		oseen[o] = true
		if revealed.has(o):
			errors.append(_issue("obstacle_revealed", "障碍格不能同时是初始翻开格 (%d,%d)" % [o.x, o.y], o))
	for p in revealed:
		var pos: Vector2i = p
		if pos.x < 0 or pos.y < 0 or pos.x >= cols or pos.y >= rows:
			errors.append(_issue("revealed_oob", "初始翻开格越界 (%d,%d)" % [pos.x, pos.y], pos))
		elif mseen.has(pos):
			# 注意：GDScript 字符串里不能用嵌套的双引号，这里用「」代替
			errors.append(_issue("revealed_mine", "初始翻开格是雷 (%d,%d)（「雷格 ? 后门」拦截）" % [pos.x, pos.y], pos))

	# 3.4) 雷位是否真的在盘上（形状盘/外部拓扑盘必须查；方阵盘不可能越界）
	# 【为什么需要】`LevelValidator` 只按 `size`（= 包围盒）校验雷位 ⇒ 六边形/三角盘上
	# "落在形状之外但仍在包围盒内"的雷会**静默消失**（盘上没有那个格 ⇒ 关卡少一颗雷，
	# 而所有校验都说"没问题"）。这是形状盘特有的静默数据丢失，必须显式拦。
	if not mines.is_empty() and rows > 0 and cols > 0 and not topology().is_empty():
		var on_board := {}
		for p in grid().all_positions():
			on_board[p] = true
		for m in mines:
			if not on_board.has(m):
				errors.append(_issue("mine_off_board", "雷位不在盘上（形状盘/外部拓扑盘上的空位）：(%d,%d)" % [m.x, m.y], m))

	# 3.5) 拓扑体检（复用仓库自带审计器 + 逐格定位度数异常）
	# 体检结果按结构签名缓存：它只依赖拓扑（行/列/邻域/障碍/外部盘），与雷位/规则无关
	# ⇒ 改雷位不必重跑（审计在 64x64 环绕盘上不便宜，而"改一格就审计全盘"是编辑器卡顿的主因之一）。
	if rows > 0 and cols > 0:
		var topo_audit := topology()
		if not topo_audit.is_empty():
			var sig := struct_signature()
			if sig != _audit_sig:
				_audit_sig = sig
				_audit_errors = []
				_audit_warnings = []
				var ag := grid()   # 复用缓存的棋盘（不要再 setup_from_topo 一遍）
				var audit := AdjacencyBuilder.audit(ag)
				if not bool(audit["ok"]):
					_audit_errors.append(_issue("topology", "邻接表体检未通过：%s" % "；".join(audit["problems"])))
				# 孤立格：有邻域定义却一个邻居都没有（偏移写错、或被障碍隔开）——
				# audit 只给整表级结论，这里逐格给坐标，UI 才能高亮到点上。
				# **只对编辑器自己生成的方阵邻域告警**：外部拓扑（六边形/三角/放射环…）里
				# 单个格没有邻居完全可能是作者的设计，对别人的盘指手画脚只会刷屏。
				if ag.cell_count() > 1 and foreign_topology.is_empty() and shape_kind == "":
					for p in ag.all_positions():
						if ag.get_neighbors(p).is_empty():
							_audit_warnings.append(_issue("isolated_cell",
								"该格没有任何邻居（排版偏移写错，或被障碍隔开）", p))
			for e in _audit_errors:
				errors.append(e)
			for w2 in _audit_warnings:
				warnings.append(w2)

	# 4) 规则（spec 走仓库自己的校验器；非 spec 走注册表解析）
	if not rule_spec.is_empty():
		# 用「编辑期校验」而不是裸 SpecSchema.validate：用户按一次「试玩」或「用这个配方」之后，
		# 这条规格就已经注册进全局表，而校验器的"id 必须全局唯一"会把它**自己**判成错 ⇒
		# 状态栏 / 本盘问题 / 验证结论 / 生成分享包 会一起报一条用户根本修不了的"已被注册"
		#（2026-10-02 以小白身份实测抓到，是"这编辑器没法用"的元凶）。
		# 只有"注册表里那条与本规格**同源**"才豁免；换成另一条同 id 的规格仍照实报错。
		var sv := SpecHelper.validate_spec_for_editing(rule_spec)
		if not bool(sv.get("ok", false)):
			for e in sv.get("errors", []):
				errors.append(_issue("spec", "规则没通过检查：%s" % str(e)))
		for w in sv.get("warnings", []):
			warnings.append(_issue("spec_warn", "规则提醒：%s" % str(w)))
	var rule := rule_object()
	if rule == null:
		errors.append(_issue("rule_missing", "规则未注册/未解析：%s" % rule_id_effective()))
	else:
		# 几何兼容：拓扑盘（环绕/自定义邻域/障碍）上 RECT_ONLY 规则会被生成器**回退 classic**
		#（core/puzzle_generator.gd:441-444 的门控），这是"规则看起来生效其实没生效"的经典坑。
		var topo := topology()
		if not topo.is_empty() and rule.has_method("supports_topology") and not bool(rule.call("supports_topology")):
			# 说人话：小白看到的是"数字突然全没了"，所以先讲现象，再给三条可执行的出路。
			#（原句是"只支持矩形盘（RECT_ONLY）⇒ 生成期会回退 classic"，2026-10-02 实测小白完全看不懂。）
			errors.append(_issue("geom_conflict",
				"这条规则用的是「具体方向」（上下左右/斜角），只认方方正正的棋盘；"
				+ "而你现在改了「邻域 / 环绕边界 / 加了障碍」⇒ 数字会算不出来，生成关卡时也会退回普通扫雷。"
				+ "请把棋盘改回方形；或改用「所有相邻格」那条配方；或让 AI 按「相邻格」重写这条规则。"))

	# 4.5) 反向几何坑：**「按相邻格定义」的规则 × 普通方盘 = 数字全 0**（而且平台不报错）
	# `SpecRulePlugin.compute_clue` 对 `refs="topo"` 直接返回 empty_value（core/spec_rule_plugin.gd:151-156），
	# 而普通方阵盘（RectGrid）走的正是 compute_clue ⇒ 每格数字都变成 0。
	# 零代码路径（让 AI 按"相邻格"写规则）最容易踩它：小白看到满盘 0 只会以为编辑器坏了 ⇒
	# 必须显式说明原因并给出**可执行的出路**（打开环绕 / 换形状盘 / 改成固定方向写法）。
	if not rule_spec.is_empty() and topology().is_empty():
		var clue_v: Variant = rule_spec.get("clue", {})
		if clue_v is Dictionary and str((clue_v as Dictionary).get("refs", "")) == "topo":
			warnings.append(_issue("topo_needs_table",
				"这条规则按「相邻格」定义（refs=\"topo\"），而当前是**普通方盘**（没有邻接表）：数字会全显示 0。"
				+ "请勾选「环绕边界」或换六边形盘；或让 AI 改成「固定方向 + geometry=\"rect_only\"」的写法。"))

	# 5) 结构校验（复用仓库既有校验器：保证"能保存的必定能加载"）
	if mines.size() > 0 and errors.is_empty():
		var ls := LevelValidator.validate_structure(to_level_json())
		if not bool(ls["ok"]):
			errors.append(_issue("structure", str(ls["reason"])))

	# 6) 不编辑但会原样保留的字段：如实提醒（避免作者以为编辑器"看懂"了它们）
	if shape_kind != "":
		warnings.append(_issue("shape_active",
			"当前是**形状盘**（%s）：棋盘由 ShapeGenerator 生成，「邻域偏移 / 环绕边界 / 含自身」不适用；"
			% shape_kind + "编辑器只编辑雷位、障碍与规则（盘型随形状参数变化）"))
	if not foreign_topology.is_empty():
		warnings.append(_issue("foreign_topology",
			"该盘使用**外部拓扑**（六边形/三角/自定义轮廓等，非本编辑器的方阵邻域）："
			+ "「邻域偏移 / 环绕边界 / 含自身」控件对它不适用，编辑器只编辑雷位、障碍与规则；盘型原样保留"))
	if not _revealed_extras.is_empty():
		warnings.append(_issue("revealed_extras", "该关卡含遮蔽区间等附加 revealed 条目：编辑器不编辑，导出时原样保留"))
	if passthrough.has("variant") or passthrough.has("clue_def"):
		warnings.append(_issue("foreign_variant", "该关卡用内置线索变体（variant/clue_def）定义线索：预览按规则口径计算，可能与其语义不同"))

	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings}


## 错误/警告里出现的格坐标（UI 高亮用；去重、剔除 (-1,-1)）。
func highlight_cells(report: Dictionary = {}) -> Array[Vector2i]:
	var r := report if not report.is_empty() else validate()
	var out: Array[Vector2i] = []
	for bucket in ["errors", "warnings"]:
		for it in r.get(bucket, []):
			var pos: Vector2i = (it as Dictionary)["pos"]
			if pos.x >= 0 and pos.y >= 0 and not out.has(pos):
				out.append(pos)
	return out


static func _issue(code: String, text: String, pos := Vector2i(-1, -1)) -> Dictionary:
	return {"code": code, "text": text, "pos": pos}


# ==================== 规则注册 / 试玩 ====================

## 编辑期把"声明的总雷数"改回"未声明"（-1），由 `total_mines_for_solving()` 按实际雷位推导。
## 【为什么需要】关卡 JSON 里的 `total_mines` 是**导入时**留下的记录；用户在编辑器里增删雷之后它就过期了，
## 于是状态栏/本盘问题会报「声明的总雷数 N 与实际雷位 M 颗不一致（导出按声明值写入 ⇒ 求解必然矛盾）」——
## 而界面上**没有任何地方**能改这个值 ⇒ 试玩与生成分享包被永久挡住。
## 2026-10-02 以小白身份真机实测复现：打开上次的存档（0 雷）→ 改雷数 → 随机布雷 → 点试玩
## 得到「先修好这些问题再试玩：声明的总雷数 0 与实际雷位 1 颗不一致…」。
## 语义上：编辑器编辑的就是"这一盘真实的雷"，所以编辑动作之后一律以实际为准。
func sync_declared_total() -> void:
	declared_total_mines = -1


## 把文档里的 spec 注册进全局注册表（**只在真的要试玩/验证时调用**，
## 打字过程中不注册的原因见 `rule_object()`）。已注册同 id ⇒ 视为成功（幂等）。
func register_rule() -> Dictionary:
	if rule_spec.is_empty():
		return {"ok": true, "reason": "使用已注册规则/内置 classic", "id": rule_id_effective()}
	var rid := str(rule_spec.get("id", ""))
	if rid != "" and RuleRegistry.default().resolve(StringName(rid)) != null:
		return {"ok": true, "reason": "规则 %s 已注册，跳过" % rid, "id": rid}
	var r := SpecRulePlugin.register_from_json(JSON.stringify(rule_spec))
	if not bool(r.get("ok", false)):
		return {"ok": false, "reason": _join(r.get("errors", [])), "id": ""}
	return {"ok": true, "reason": "", "id": str(r.get("id", rid))}


## 一键试玩：注册规则 → 直接吃 dict 建 Board（不落盘）。
## 返回 null = 失败（原因见 validate()/register_rule()）。
func build_board() -> Board:
	var reg := register_rule()
	if not bool(reg["ok"]):
		return null
	var b := Board.new()
	b.load_level(to_level_json())
	return b


## 从关卡 JSON 里取出随包携带的 spec 并注册（**分享闭环的接收端**：
## 别人发来的关卡自带规则，载入即可玩）。未携带 spec ⇒ ok=true 且 id 为空。
static func register_spec_from_level(level: Dictionary) -> Dictionary:
	var spec := spec_of_level(level)
	if spec.is_empty():
		return {"ok": true, "reason": "关卡未携带规则 spec", "id": ""}
	var rid := str(spec.get("id", ""))
	if rid != "" and RuleRegistry.default().resolve(StringName(rid)) != null:
		return {"ok": true, "reason": "规则已注册", "id": rid}
	var r := SpecRulePlugin.register_from_json(JSON.stringify(spec))
	if not bool(r.get("ok", false)):
		return {"ok": false, "reason": _join(r.get("errors", [])), "id": ""}
	return {"ok": true, "reason": "", "id": str(r.get("id", rid))}


static func spec_of_level(level: Dictionary) -> Dictionary:
	var custom: Variant = level.get("custom", {})
	if custom is Dictionary:
		var spec: Variant = (custom as Dictionary).get("spec", {})
		if spec is Dictionary and not (spec as Dictionary).is_empty():
			return (spec as Dictionary).duplicate(true)
	return {}


static func _join(errs: Variant) -> String:
	var parts: Array[String] = []
	if errs is Array or errs is PackedStringArray:
		for e in errs:
			parts.append(str(e))
	return "；".join(parts)


# ==================== JSON 双射 ====================

func to_level_json() -> Dictionary:
	return _level_dict(true)


## 关卡字典。`include_topology = false` 时**不写 topology**——撤销快照走这一支：
## topology 是**派生数据**（64x64 环绕盘展开成 GDScript 结构约数 MB），快照存它会让
## 50 步撤销吃掉上百 MB 内存（2026-10-02 复查发现；见 `snapshot()`）。
func _level_dict(include_topology: bool) -> Dictionary:
	var out := passthrough.duplicate(true)
	out["name"] = title
	out["size"] = {"rows": rows, "cols": cols}
	out["total_mines"] = total_mines_for_solving()

	# 落盘顺序确定（r 升序、c 升序）：diff 友好、测试可逐字节比对
	var sorted_mines: Array[Vector2i] = []
	sorted_mines.assign(mines)
	sorted_mines.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	var ml: Array = []
	for m in sorted_mines:
		ml.append({"r": m.y, "c": m.x})
	out["mines"] = ml

	var rl: Array = []
	var rl_sorted: Array[Vector2i] = []
	rl_sorted.assign(revealed.keys())
	rl_sorted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	for p in rl_sorted:
		var e := {"r": p.y, "c": p.x}
		if _revealed_merge.has(p):
			var raw: Dictionary = _revealed_merge[p]
			for k in raw:
				if k != "r" and k != "c":
					e[k] = raw[k]
		rl.append(e)
	for extra in _revealed_extras:
		rl.append(extra)   # 带 interval 的条目原样写回（不编辑，但不丢）
	out["revealed"] = rl

	var rid := rule_id_effective()
	if not rule_spec.is_empty():
		out["rule_level"] = true
		out["clue_rule"] = rid
	elif clue_rule_id != "":
		out["rule_level"] = true
		out["clue_rule"] = clue_rule_id
	if not global_rule_ids.is_empty():
		out["global_rules"] = Array(global_rule_ids)

	var custom: Dictionary = {}
	var prev: Variant = out.get("custom", {})
	if prev is Dictionary:
		custom = (prev as Dictionary).duplicate(true)
	if not rule_spec.is_empty():
		custom["schema_id"] = SCHEMA_ID
		custom["spec"] = rule_spec.duplicate(true)
	if not warp_points.is_empty():
		custom["warp_points"] = _cells_json(warp_points)
	if not regions.is_empty():
		custom["regions"] = regions.duplicate(true)
	if not custom.is_empty():
		out["custom"] = custom

	if include_topology:
		var topo := topology()
		if not topo.is_empty():
			out["topology"] = topo
	return out


## 撤销/重做快照：只存**编辑状态**（结构字段 + 雷/障碍/翻开 + 规则 + 不认识的字段），
## **不存派生的 topology**。恢复时 topology 由结构字段重算（一次性约 50ms），
## 而外部拓扑（六边形/三角等）重算不出来 ⇒ 存**引用**：它在会话里只被整体替换、
## 从不原地修改（`load_from` 用 duplicate、`_carve_holes` 返回新字典），
## 因此多份快照共享同一对象是安全的，也不会复制出多份大表。
func snapshot() -> Dictionary:
	return {
		"level": _level_dict(false),
		# ⚠ 必须**显式**存结构源：wrap / dirs / include_self 在关卡 JSON 里是写在
		# `topology.editor` 元数据内的，障碍更是"positions 里没有谁"反推出来的——
		# 既然快照省掉了 topology，就必须自己带结构源，否则恢复出来的是"方阵 + 无邻域 + 无障碍"
		#（本文件的测试当场抓到：三处断言全红）。
		"struct": {
			"wrap": wrap,
			"include_self": include_self,
			"dirs": dirs.duplicate(),
			"obstacles": obstacles.duplicate(),
		},
		"foreign": foreign_topology,
	}


func restore(snap: Dictionary) -> bool:
	if snap.is_empty():
		return false
	var level: Variant = snap.get("level", {})
	if not (level is Dictionary):
		return false
	if not bool(load_from(level)["ok"]):
		return false
	var st: Variant = snap.get("struct", {})
	if st is Dictionary:
		var s: Dictionary = st
		wrap = bool(s.get("wrap", false))
		include_self = bool(s.get("include_self", false))
		dirs.assign(s.get("dirs", []))
		obstacles.assign(s.get("obstacles", []))
	var f: Variant = snap.get("foreign", {})
	foreign_topology = f if f is Dictionary else {}
	return true


func load_from(level: Dictionary) -> Dictionary:
	var sz: Variant = level.get("size", {})
	if not (sz is Dictionary):
		return {"ok": false, "reason": "关卡缺少 size"}
	rows = int((sz as Dictionary).get("rows", 0))
	cols = int((sz as Dictionary).get("cols", 0))
	if rows < 1 or cols < 1:
		return {"ok": false, "reason": "关卡尺寸非法（%dx%d）" % [rows, cols]}
	title = str(level.get("name", title))

	mines = _parse_cells(level.get("mines", []))
	declared_total_mines = int(level.get("total_mines", -1))
	revealed = {}
	_revealed_extras = []
	_revealed_merge = {}
	for rc in level.get("revealed", []):
		if not (rc is Dictionary):
			continue
		var d: Dictionary = rc
		var pos := Vector2i(int(d.get("c", -1)), int(d.get("r", -1)))
		if d.has("interval"):
			# 遮蔽区间（`?` 格）不是"已翻开的线索格"：不进编辑集合，但必须原样写回
			#（本编辑器不编辑它 ≠ 可以把它丢掉）。
			_revealed_extras.append(d.duplicate(true))
			continue
		revealed[pos] = null
		if d.size() > 2:
			# 带附加键的条目（如运行期不读的 value）：按格记原文，导出时**合并回同一条**。
			# 不能整条另存——否则同一格会出现两条 revealed ⇒ 加载器报"初始翻开格重复"。
			_revealed_merge[pos] = d.duplicate(true)

	obstacles = []
	dirs = []
	wrap = false
	include_self = false
	foreign_topology = {}
	# 形状族是**当前会话的编辑选择**，不是关卡字段 ⇒ 载入关卡时清空
	#（载入进来的异形盘一律走 foreign_topology 原样保留那条路）
	shape_kind = ""
	shape_params = {}
	var topo: Variant = level.get("topology", {})
	if topo is Dictionary and not (topo as Dictionary).is_empty():
		var t: Dictionary = topo
		if t.has("editor"):
			# 本编辑器产出的拓扑：读元数据，障碍由其 positions 缺项反推
			var meta := WrapTopology.read_editor_meta(t)
			wrap = bool(meta["wrap"])
			include_self = bool(meta["include_self"])
			dirs.assign(meta["dirs"])
		else:
			# 外部拓扑（六边形/三角/轮廓…）：原样保留，**不**按 dirs/wrap 重建
			foreign_topology = t.duplicate(true)
		var present := {}
		for p in t.get("positions", []):
			var pd: Dictionary = p
			present[Vector2i(int(pd["x"]), int(pd["y"]))] = true
		for y in rows:
			for x in cols:
				if not present.has(Vector2i(x, y)):
					obstacles.append(Vector2i(x, y))

	rule_spec = {}
	clue_rule_id = ""
	global_rule_ids = []
	if bool(level.get("rule_level", false)) or str(level.get("clue_rule", "")) != "":
		clue_rule_id = str(level.get("clue_rule", ""))
		for g in level.get("global_rules", []):
			global_rule_ids.append(str(g))
	rule_spec = spec_of_level(level)
	# spec 自带 id 时以 spec 为准（Board 只认 clue_rule，两者不一致会让"编辑的规则"与"跑的规则"不同）
	if not rule_spec.is_empty() and clue_rule_id == "":
		clue_rule_id = str(rule_spec.get("id", ""))

	warp_points = []
	regions = []
	var custom: Variant = level.get("custom", {})
	if custom is Dictionary:
		warp_points = _parse_cells((custom as Dictionary).get("warp_points", []))
		var rg: Variant = (custom as Dictionary).get("regions", [])
		regions = (rg as Array).duplicate(true) if rg is Array else []

	passthrough = {}
	var known := ["name", "size", "total_mines", "mines", "revealed", "rule_level", "clue_rule",
		"global_rules", "topology", "custom"]
	for k in level:
		if not known.has(k):
			passthrough[k] = level[k]
	return {"ok": true, "reason": ""}


func _cells_json(cells: Array[Vector2i]) -> Array:
	var out: Array = []
	for p in cells:
		out.append({"r": p.y, "c": p.x})
	return out


static func _parse_cells(raw: Variant) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not (raw is Array):
		return out
	for e in raw:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		var x := int(d.get("c", d.get("x", 0)))
		var y := int(d.get("r", d.get("y", 0)))
		var pos := Vector2i(x, y)
		if not out.has(pos):   # 去重：JSON 允许手写重复，模型不允许（validate 会报，这里先收敛）
			out.append(pos)
	return out
