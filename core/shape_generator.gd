# shape_generator.gd —— 形状生成器：从参数生成「通用邻接表」拓扑（{positions, adjacency}）。
#
# 为什么需要：平台此前只能**消费**拓扑（board.gd / AdjacencyGrid.setup_from_topo），
# 却没有「按参数造形状」的入口——拓扑样例只存在于测试常量里。本模块补上这个缺口，
# 产出格式与 AdjacencyGrid.setup_from_topo 的「形式 1（边列表）」完全一致。
#
# 纯函数：static + RefCounted，无状态、不引用引擎/UI/autoload、不做随机。
# 三族形状（规则均从原版游戏字节码提取并经数据实证：60 关全量「共边 ⊂ 邻接」100% 覆盖、0 例外）：
#   (a) build_holed_grid —— 挖洞方格：满格 rows×cols 的 Moore 8 邻图，再删洞格。
#   (b) build_hex        —— 蜂窝：轴向坐标 (r,c) 裁剪成六边形盘，6 邻。
#   (c) build_t488       —— 截角正方形镶嵌 4.8.8：主格八边形 + 填隙小方块。
#
# 不变量（三族共同，test_shape_generator.gd 逐项断言）：
#   · 坐标全部为**非负整数**——board.gd 直接 setup_from_topo() 且**不做** normalized，
#     负坐标会让 CP-SAT 的 cell 索引（从 0 起）越界。
#   · 邻接**对称、无自环、无重复**（同一无向边只出现一条）。
#   · 每个邻接端点都必须存在于 positions。
#   · 坐标字典一律 {"x": c, "y": r}（x=列, y=行），与项目 Vector2i(c, r) 约定、JSON 口径一致。
#
# 几何风格字段（T4）：产物除 positions/adjacency 外**追加**两个**展示用**字段，不参与任何拓扑语义：
#   · "style"  —— "holed_grid" / "hex" / "t488"（渲染层据此决定方阵还是六边形排布）
#   · "params" —— {"size": N}（hex / t488；holed_grid 的形状信息已在 positions/adjacency 里，不重复写）
#   setup_from_topo 读它们（AdjacencyGrid.style / style_params）、_topology_to_dict 原样落盘，
#   于是「生成 → 落盘 → 载入 → 渲染」全程带着风格走。**拓扑数据（positions/adjacency）本身不受影响**。
class_name ShapeGenerator
extends RefCounted

## (a) Moore 8 邻域偏移（4 正交 + 4 对角）。双向都写出，去重表会把无向边收敛为一条。
const MOORE8: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]
## (b) 蜂窝 6 邻偏移。三类对称边 (r,c)-(r+1,c)、(r,c)-(r,c+1)、(r+1,c)-(r,c+1)
## 展开到 (x,y)=(c,r) 空间即下列 6 个方向（正好是标准轴向六边形的 6 个邻居方向）。
const HEX6: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, -1), Vector2i(-1, 1),
]
## (c) 八边形→正交八边形（步长 2，仅写正方向；无向边去重表兜住重复）。
const T488_OCT_ORTHO: Array[Vector2i] = [Vector2i(2, 0), Vector2i(0, 2)]
## (c) 小方块→4 个相邻八边形（对角 ±1）。
const T488_SQ_DIAG: Array[Vector2i] = [
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]


## (a) 挖洞方格（rows 行 × cols 列）。
##
## 语义 = 「先建满格 rows×cols 的 Moore 8 邻图，再删除洞格」：删格即删其**全部**关联边，
## 且**不做任何重连**（不给洞格周围补边、不改变其余格之间已有的边）。洞格不是「不可通行」，
## 而是**不存在**（Board 侧表现为「不在盘内」）。
##
## 参数：
##   rows/cols —— 满格的行/列数（坐标 c∈[0,cols)、r∈[0,rows)）。
##   holes     —— 洞坐标，元素接受 Vector2i 或 {"x":int,"y":int}（JSON 口径）两种形式。
## 校验策略：
##   · rows/cols <= 0 → push_error + 返回空拓扑（连满格都建不出来，没有可降级的语义）。
##   · 单个洞越界/无法解析 → push_error + **跳过该洞**：洞是逐格数据，一条坏数据不该让
##     整盘失效（板子仍可用）；但必须报错，否则会静默产出与关卡数据不符的形状。
static func build_holed_grid(rows: int, cols: int, holes: Array = []) -> Dictionary:
	if rows <= 0 or cols <= 0:
		push_error("ShapeGenerator.build_holed_grid: rows/cols 必须为正整数（收到 rows=%d, cols=%d）" % [rows, cols])
		return _empty()
	var cells := {}
	for r in rows:
		for c in cols:
			cells[Vector2i(c, r)] = true
	for h in holes:
		var parsed: Variant = _to_pos(h)
		if parsed == null:
			push_error("ShapeGenerator.build_holed_grid: 洞坐标无法解析（需 Vector2i 或 {x,y}）：%s" % str(h))
			continue
		var hole: Vector2i = parsed
		if hole.x < 0 or hole.x >= cols or hole.y < 0 or hole.y >= rows:
			push_error("ShapeGenerator.build_holed_grid: 洞坐标越界已跳过 (%d,%d)（盘面 %d 列 × %d 行）" % [hole.x, hole.y, cols, rows])
			continue
		cells.erase(hole)
	var topo := _graph_from_dirs(cells, MOORE8)
	topo["style"] = "holed_grid"   # 展示用标记：当前仍按包围盒方阵渲染（洞格已从 positions 里删掉）
	return topo


## (b) 蜂窝（六边形盘），边长为 size。
##
## 轴向坐标 (r, c)，r、c ∈ [0, size)；按 abs(r + c - (size - 1)) <= (size - 1) / 2 裁剪成六边形盘
## （整除）。盘心 = r+c = size-1 的格：size=3 → 7 格（盘心 6 邻）、size=5 → 19 格。
## 邻接 = 三个对称偏移方向 (r,c)-(r+1,c)、(r,c)-(r,c+1)、(r+1,c)-(r,c+1)，全部带
## 「两端都存在」守卫 ⇒ 盘内格 6 邻、盘边格 3~4 邻。
##
## 非负性：原版以盘心为原点（会产生负坐标），本函数把原点固定在 (0,0)、窗口取 [0,size)，
## 裁剪不会选中负格 ⇒ 输出天然非负，**无需整体平移**（与 board/CP-SAT 的非负口径一致）。
static func build_hex(size: int) -> Dictionary:
	if size <= 0:
		push_error("ShapeGenerator.build_hex: size 必须为正整数（收到 %d）" % size)
		return _empty()
	var half := (size - 1) / 2
	var cells := {}
	for r in size:
		for c in size:
			if absi(r + c - (size - 1)) <= half:
				cells[Vector2i(c, r)] = true
	var topo := _graph_from_dirs(cells, HEX6)
	# "hex" = 渲染层改走六边形几何（ui/board_view.gd）；params.size 供几何/自校验复核。
	topo["style"] = "hex"
	topo["params"] = {"size": size}
	return topo


## (c) 截角正方形镶嵌 4.8.8（主格 = 八边形，填隙格 = 小方块）。
##
## 原版用半整数坐标（八边形落脚在整数、小方块在 (c+0.5, r+0.5)），Vector2i 装不下，
## 故整体 **×2 整数化**：八边形 (2c, 2r)，小方块 (2c+1, 2r+1)（c、r 见下）。
## 邻接：八边形正交 4 邻（(2c,2r)-(2c+2,2r)、(2c,2r)-(2c,2r+2)，带边界守卫）；
## 每个小方块连其 4 个相邻八边形（(2c+1,2r+1) ↔ (2c,2r)/(2c+2,2r)/(2c,2r+2)/(2c+2,2r+2)）。
## ⇒ 八边形 8 邻（4 个正交八边形 + 4 个小方块）、小方块 4 邻（全是八边形）。
##   注意：**不是**「4 对角八边形」——对角线位置被小方块占着，那是文档错误。
static func build_t488(size: int) -> Dictionary:
	if size <= 0:
		push_error("ShapeGenerator.build_t488: size 必须为正整数（收到 %d）" % size)
		return _empty()
	var cells := {}
	for r in size:
		for c in size:
			cells[Vector2i(2 * c, 2 * r)] = true
	for r in size - 1:
		for c in size - 1:
			cells[Vector2i(2 * c + 1, 2 * r + 1)] = true
	var seen := {}
	var adjacency: Array = []
	for r in size:
		for c in size:
			var oct := Vector2i(2 * c, 2 * r)
			for dir in T488_OCT_ORTHO:
				_add_edge(cells, seen, adjacency, oct, oct + dir)
	for r in size - 1:
		for c in size - 1:
			var sq := Vector2i(2 * c + 1, 2 * r + 1)
			for dir in T488_SQ_DIAG:
				_add_edge(cells, seen, adjacency, sq, sq + dir)
	# 展示用标记：4.8.8 当前仍按包围盒方阵渲染（八边形/小方块的混合几何留待后续渲染任务）。
	return {
		"positions": _positions_of(cells),
		"adjacency": adjacency,
		"style": "t488",
		"params": {"size": size},
	}


## 便利入口（供上层接线用）：按 kind + params 直接产出可用的 AdjacencyGrid。
## kind / params：
##   "holed_grid" —— {"rows":R, "cols":C, "holes":[...]}（holes 可省）
##   "hex"        —— {"size":N}
##   "t488"       —— {"size":N}
## 形状为空、参数非法（build_* 已 push_error）、kind 未注册 → push_error 并返回 null
## （调用方据此回退矩形/报错；返回 null 而非空 grid，避免「空盘」被误当成合法关卡）。
static func to_adjacency_grid(kind: String, params: Dictionary) -> AdjacencyGrid:
	var topo: Dictionary = {}
	match kind:
		"holed_grid":
			var holes: Array = params.get("holes", [])
			topo = build_holed_grid(int(params.get("rows", 0)), int(params.get("cols", 0)), holes)
		"hex":
			topo = build_hex(int(params.get("size", 0)))
		"t488":
			topo = build_t488(int(params.get("size", 0)))
		_:
			push_error("ShapeGenerator.to_adjacency_grid: 未注册的形状 kind \"%s\"（可用：holed_grid/hex/t488）" % kind)
			return null
	var positions: Array = topo["positions"]
	if positions.is_empty():
		return null
	var grid := AdjacencyGrid.new()
	# **原样**（含 style / params）交给 setup_from_topo：它会读出风格 → grid.style / style_params，
	# 渲染层与落盘侧都从这里取，故本入口无需再搬字段。
	grid.setup_from_topo(topo)
	return grid


## 通用建图：格集 + 每格邻居方向表 → {positions, adjacency}。
## 方向表可含双向（±）偏移：规范去重表把重复的无向边收敛为一条。
static func _graph_from_dirs(cells: Dictionary, dirs: Array[Vector2i]) -> Dictionary:
	var seen := {}
	var adjacency: Array = []
	for pos: Vector2i in cells:
		for dir in dirs:
			_add_edge(cells, seen, adjacency, pos, pos + dir)
	return {"positions": _positions_of(cells), "adjacency": adjacency}


## 收一条无向边：过滤自环 / 端点缺失 / 重复（同一无向边只留一条）。
## 端点按 (x,y) 字典序写入 a/b，使规范键与输出内容一致（键序 = 写入次序）。
static func _add_edge(cells: Dictionary, seen: Dictionary, out: Array, a: Vector2i, b: Vector2i) -> void:
	if a == b or not cells.has(b):
		return
	var lo := a
	var hi := b
	if b.x < a.x or (b.x == a.x and b.y < a.y):
		lo = b
		hi = a
	var key := "%d,%d|%d,%d" % [lo.x, lo.y, hi.x, hi.y]
	if seen.has(key):
		return
	seen[key] = true
	out.append({"a": {"x": lo.x, "y": lo.y}, "b": {"x": hi.x, "y": hi.y}})


## 格集 → positions（{"x":int,"y":int} 数组）。顺序 = 格集插入顺序 = 构造顺序（确定性）。
static func _positions_of(cells: Dictionary) -> Array:
	var out: Array = []
	for pos: Vector2i in cells:
		out.append({"x": pos.x, "y": pos.y})
	return out


## 归一化外部传入的格坐标：接受 Vector2i 或 {"x":int,"y":int}；其余 → null。
static func _to_pos(v: Variant) -> Variant:
	if v is Vector2i:
		return v
	if v is Dictionary and v.has("x") and v.has("y"):
		return Vector2i(int(v["x"]), int(v["y"]))
	return null


## 空拓扑（参数非法时的统一返回；调用方按「无格」处理）。
static func _empty() -> Dictionary:
	return {"positions": [], "adjacency": []}
