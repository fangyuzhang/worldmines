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
#   (d) build_from_mask  —— mask 驱动（T7，原创能力）：ASCII 轮廓（#/X/1 = 有格）按 style
#       语义建成同族形状——「任意轮廓图案」（具象剪影 / 对称花纹 / 分形符号）成为可玩棋盘。
#       与 (a)/(b)/(c) 的同形交叉验证（两条独立路径逐字节一致）见 test_shape_generator.gd。
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
## (d) mask 字符集：有格 = #/X/1，空 = . / 0 / 空格（其余字符 = 非法，报错不静默）。
const MASK_FILLED := "#X1"
const MASK_EMPTY := ".0 "
## (d) mask 可用的 style（与三族参数化生成器一一对应；未注册 → 报错 + 空拓扑）。
const MASK_STYLES: Array[String] = ["holed_grid", "hex", "t488"]


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


## (d) mask 驱动生成（T7）：ASCII 轮廓 → 同族邻接拓扑（「任意轮廓图案」直接成关的入口）。
##
## mask 每行等长；`#`/`X`/`1` = 有格，`.`/`0`/空格 = 空。行索引 = y（row），列索引 = x（col）。
## 语义按 style 解释（style 名与三族参数化生成器一一对应；未注册 → push_error + 空拓扑）：
##   · "holed_grid"：格 = (x=col, y=row)，Moore 8 邻——等价于「rows×cols 满格挖掉 mask 里的 '.'」
##     （对照 build_holed_grid(rows, cols, holes)：holes = mask 的空格集）。
##   · "hex"       ：格 = (x=col, y=row) 作为轴向坐标 (c, r)（与 build_hex 同语义），6 邻——
##     盘内格照写即得任意裁剪的蜂窝（build_hex 的六边形盘是它的特例）。
##   · "t488"      ：mask 行列 = 八边形格阵索引 (c, r) → 八边形 (2c, 2r)；**自动补小方块**：
##     (2c+1, 2r+1) 当其 4 个相邻八边形 (2c,2r)/(2c+2,2r)/(2c,2r+2)/(2c+2,2r+2) 全在时
##     加入并连边（与 build_t488 同款填隙规则，由 _t488_from_mask_cells 实现）。
## 校验（任一不合法 → push_error + 空拓扑，绝不静默产半成品）：
##   style 未注册 / mask 空 / 行非字符串 / 行长不一致 / 行长为 0 / 非法字符 / 无任何格。
## 输出除 positions/adjacency 外附带 style（= 入参）与 params（原样透传；调用方可塞
## {"mask": mask} 供落盘审计——见 to_adjacency_grid 的 "mask" 分支）。
## 建图/去重全部复用 _graph_from_dirs / _add_edge（无复制粘贴）：同形产出与三族参数化生成器
## **逐字节一致**——positions 顺序 = 构造顺序、邻接顺序 = 格序 × 方向表序，test 里直接 assert_eq。
static func build_from_mask(style: String, mask: Array, params: Dictionary = {}) -> Dictionary:
	if not MASK_STYLES.has(style):
		push_error("ShapeGenerator.build_from_mask: 未注册的 style \"%s\"（可用：%s）" % [style, "/".join(MASK_STYLES)])
		return _empty()
	if mask.is_empty():
		push_error("ShapeGenerator.build_from_mask: mask 为空（至少一行；行索引 = y，列索引 = x）")
		return _empty()
	var width := -1
	for i in mask.size():
		var row_v: Variant = mask[i]
		if not (row_v is String):
			push_error("ShapeGenerator.build_from_mask: mask[%d] 不是字符串：%s" % [i, str(row_v)])
			return _empty()
		var row: String = row_v
		if width < 0:
			width = row.length()
		elif row.length() != width:
			push_error("ShapeGenerator.build_from_mask: mask 行长不一致（第 %d 行 %d 列，首行 %d 列）" % [
				i, row.length(), width])
			return _empty()
	if width == 0:
		push_error("ShapeGenerator.build_from_mask: mask 行长必须 ≥ 1（收到 0 列）")
		return _empty()
	var cells := {}
	for r in mask.size():
		var row: String = mask[r]
		for c in width:
			var ch := row[c]
			if MASK_FILLED.contains(ch):
				cells[Vector2i(c, r)] = true
			elif not MASK_EMPTY.contains(ch):
				push_error("ShapeGenerator.build_from_mask: mask[%d][%d] 含非法字符 \"%s\"（有格 = #/X/1，空 = . / 0 / 空格）" % [
					r, c, ch])
				return _empty()
	if cells.is_empty():
		push_error("ShapeGenerator.build_from_mask: mask 里没有任何格（全是空字符）")
		return _empty()
	# M6（2026-09-21 审计修复）：图案必须**贴左上角**（cells 的最小坐标必须是 (0,0)）。
	# 原因：下游（Board.load_level 的拓扑 / AdjacencyGrid.normalized）会把坐标平移非负，
	# 而落盘的 params.mask 是原样透传 —— mask 带左上留白时两者不再一一对应（审计链断、
	# bbox ≠ mask 行列数，gen 工具的 mask 分支也会把 bbox 校验判红）。与其默默补偿，不如
	# 在入口就要求作者把图案贴到左上（改一行即可）。
	var min_x := 1 << 30
	var min_y := 1 << 30
	for pos: Vector2i in cells:
		min_x = mini(min_x, pos.x)
		min_y = mini(min_y, pos.y)
	if min_x != 0 or min_y != 0:
		push_error("ShapeGenerator.build_from_mask: 图案必须贴左上角（实测最小坐标 (%d,%d)）——mask 带留白会被下游 normalized 平移而 params.mask 原样透传，两者将不再对应" % [min_x, min_y])
		return _empty()
	var topo: Dictionary = {}
	match style:
		"holed_grid":
			topo = _graph_from_dirs(cells, MOORE8)
		"hex":
			topo = _graph_from_dirs(cells, HEX6)
		"t488":
			topo = _t488_from_mask_cells(cells, mask.size(), width)
		_:
			# 不可达（MASK_STYLES 已拦）；兜底报错，防两处名单漂移时静默走错分支
			push_error("ShapeGenerator.build_from_mask: style \"%s\" 无建图分支（MASK_STYLES 与 match 漂移）" % style)
			return _empty()
	topo["style"] = style
	topo["params"] = params
	return topo


## (d) T488 的 mask 支线：mask 格集（八边形格阵索引 (c,r)）→ 八边形 (2c,2r) + 自动补小方块。
## 先建八边形层（正交 4 邻：复用 _graph_from_dirs），再逐 2×2 窗口补小方块 (2c+1,2r+1)
## （4 个相邻八边形全在才补），并复用 _add_edge 连「方块 ↔ 4 八边形」。
## 插入次序（八边形在前 → 方块按窗口行列序在后）与 build_t488 一致 ⇒ 同形产出逐字节相同。
static func _t488_from_mask_cells(mask_cells: Dictionary, rows: int, cols: int) -> Dictionary:
	var cells := {}
	for r in rows:
		for c in cols:
			if mask_cells.has(Vector2i(c, r)):
				cells[Vector2i(2 * c, 2 * r)] = true
	var topo := _graph_from_dirs(cells, T488_OCT_ORTHO)
	var seen := {}
	var adjacency: Array = topo["adjacency"]
	for r in rows - 1:
		for c in cols - 1:
			var sq := Vector2i(2 * c + 1, 2 * r + 1)
			if not (cells.has(sq + Vector2i(-1, -1)) and cells.has(sq + Vector2i(1, -1))
					and cells.has(sq + Vector2i(-1, 1)) and cells.has(sq + Vector2i(1, 1))):
				continue
			cells[sq] = true
			for dir in T488_SQ_DIAG:
				_add_edge(cells, seen, adjacency, sq, sq + dir)
	topo["positions"] = _positions_of(cells)
	return topo


## ==== (e) 等轴菱面（isometric rhombus）：60° 菱形 × 3 个朝向的「立方体阵列」 ====
##
## “看起来是立体、实际上是平面”的几何机制（规律由本项目独立推导，不引用任何外部数据）：
##   每一格都是同一个 **60° 菱形**（四边等长、夹角 60°/120°），只有 3 种朝向；
##   这 3 种朝向恰好是三维立方体「顶面 / 右面 / 左面」在等轴测（30° 轴测）投影下的形状，
##   三面两两共边 ⇒ 合围成一个正六边形，看起来就是一个立方体
##   （内部那个三面共用的顶点，就是“可见的轮廓转折”）。
##   三种朝向数量严格 1:1:1 ⇒ 每 3 格拼成一个“看起来立体的方块”。
##   眼睛数出 n 个方块，引擎里是 3n 个可点格 —— 这个「所见 ≠ 所点」的错位就是错觉本身，
##   也是它与普通方格盘在玩法上真正的区别。
##
## 构造（正六边形三分铺装）：正六边形晶格的格心
##   C(i,j) = (√3/2 · (2i + j), 1.5 · j)，格边长 = 1；每个六边形按
##   [C, V_2k, V_2k+1, V_2k+2]（V = 六边形顶点，角度 30°+60°k）切成 3 个菱形。
##   这是三分铺装的标准构造，**数学上保证无缝无重叠**，也就自动满足 2026-09-21 的
##   连通视觉契约（相邻格严格贴合）——不需要像等轴原作那样靠 0.95 收缩留缝。
##
## 坐标：一个方块 = 3 格，格键 = (i * 3 + f, j)，f ∈ {0 顶面, 1 右面, 2 左面}；
##   用整数键而非浮点，是为了让 AdjacencyGrid / CP-SAT / 存档全链路沿用既有的 Vector2i 口径。
##
## 邻接 = **共边**（严格几何判据，逐条反解成下面的表）：
##   内部格度恰为 4（同方块的另两面 + 跨方块的两个异朝向面）。
##   实测反直觉的一点：与**同朝向**面的跨方块共边 = 0 个（必须跨朝向），所以下表是
##   几何反解的结果而不是想当然，test_shape_iso_cubes 会逐边重验。
##   （备选更密口径：「共边 ∪ 共用顶点」→ 内部度 10；本族选共边，
##     因为它与玩家眼里的“明显相邻”最一致。）
const ISO_FACE_COUNT := 3
const ISO_FACE_TOP := 0
const ISO_FACE_RIGHT := 1
const ISO_FACE_LEFT := 2
## 跨方块共边表（面 → [(di, dj, 邻面)]；由几何反解）。
const ISO_CROSS_EDGES: Array = [
	[Vector3i(-1, 1, ISO_FACE_LEFT), Vector3i(0, 1, ISO_FACE_RIGHT)],
	[Vector3i(-1, 0, ISO_FACE_LEFT), Vector3i(0, -1, ISO_FACE_TOP)],
	[Vector3i(1, -1, ISO_FACE_TOP), Vector3i(1, 0, ISO_FACE_RIGHT)],
]


## 方块 (i,j) 的六边形格心（世界坐标；整体平移由调用方负责）。
static func iso_hex_center(i: int, j: int) -> Vector2:
	return Vector2(0.8660254037844386 * float(2 * i + j), 1.5 * float(j))


## 方块 (i,j) 的 6 个六边形顶点（世界坐标，外接半径 1，角度 30°+60°k）。
static func iso_hex_vertices(i: int, j: int) -> Array:
	var c := iso_hex_center(i, j)
	var out: Array = []
	for k in 6:
		var a := deg_to_rad(30.0 + 60.0 * float(k))
		out.append(c + Vector2(cos(a), sin(a)))
	return out


## 方块 (i,j) 的面 f 的 4 个顶点（世界坐标，顺时针）。
static func iso_face_polygon(i: int, j: int, f: int) -> PackedVector2Array:
	# 顶点序 = [格心, V_2k, V_2k+1, V_2k+2]：格心是一个**独立顶点**（不是 v[0]！
	# 六边形的 6 个顶点里没有格心，写错会退化成一个零面积的三角形）。
	var c := iso_hex_center(i, j)
	var v := iso_hex_vertices(i, j)
	var k := f % ISO_FACE_COUNT
	return PackedVector2Array([c, v[(2 * k) % 6], v[(2 * k + 1) % 6], v[(2 * k + 2) % 6]])


## 等轴菱面的逐格几何（世界坐标）——与其他族的 cells_geo 同口径，
## 供落盘工具直接包成 custom_shapes。顺序 = build_iso_cubes 的 positions 顺序。
static func iso_cells_geo(cols: int, rows: int, holes: Array = []) -> Array:
	var removed := _iso_removed(holes, cols, rows)
	var out: Array = []
	for j in rows:
		for i in cols:
			if removed.has(Vector2i(i, j)):
				continue
			for f in ISO_FACE_COUNT:
				out.append({"pos": Vector2i(i * ISO_FACE_COUNT + f, j),
						"poly": iso_face_polygon(i, j, f)})
	return out


## (e) 等轴菱面：方块阵列 → {positions, adjacency, style, params}。
## holes 里的方块被整体删除（三个面一起没）—— 就是“空了一个立方体”的视觉。
## 只删单个面会留下“挖穿的隧道”，留给后续的 face_holes（本次未实现，不猜语义）。
static func build_iso_cubes(cols: int, rows: int, holes: Array = []) -> Dictionary:
	if cols <= 0 or rows <= 0:
		push_error("ShapeGenerator.build_iso_cubes: cols/rows 必须为正整数（收到 %d×%d）" % [cols, rows])
		return _empty()
	var removed := _iso_removed(holes, cols, rows)
	var cells := {}
	for j in rows:
		for i in cols:
			if removed.has(Vector2i(i, j)):
				continue
			for f in ISO_FACE_COUNT:
				cells[Vector2i(i * ISO_FACE_COUNT + f, j)] = true
	if cells.is_empty():
		push_error("ShapeGenerator.build_iso_cubes: 删完洞之后没有剩下任何格子")
		return _empty()
	var seen := {}
	var adjacency: Array = []
	for pos: Vector2i in cells:
		var i := pos.x / ISO_FACE_COUNT
		var f := pos.x % ISO_FACE_COUNT
		var j := pos.y
		# 同方块：另两个面（三面两两共边）
		for g in ISO_FACE_COUNT:
			if g != f:
				_add_edge(cells, seen, adjacency, pos, Vector2i(i * ISO_FACE_COUNT + g, j))
		# 跨方块：按几何表取相应面（异朝向）
		for d: Vector3i in ISO_CROSS_EDGES[f]:
			_add_edge(cells, seen, adjacency, pos,
					Vector2i((i + d.x) * ISO_FACE_COUNT + d.z, j + d.y))
	return {"positions": _positions_of(cells), "adjacency": adjacency,
			"style": "iso_cubes",
			"params": {"cols": cols, "rows": rows, "holes": _iso_holes_echo(removed)}}


## 洞坐标归一（接受 Vector2i / {"x","y"}；越界或不可解析 → 报错 + 跳过，同 build_holed_grid 口径）。
static func _iso_removed(holes: Array, cols: int, rows: int) -> Dictionary:
	var removed := {}
	for h: Variant in holes:
		var hp: Variant = _to_pos(h)
		if hp == null:
			push_error("ShapeGenerator.build_iso_cubes: 洞坐标无法解析（需 Vector2i 或 {x,y}）：%s" % str(h))
			continue
		var p: Vector2i = hp
		if p.x < 0 or p.x >= cols or p.y < 0 or p.y >= rows:
			push_error("ShapeGenerator.build_iso_cubes: 洞坐标越界（%d,%d，方块域 %d×%d）" % [p.x, p.y, cols, rows])
			continue
		removed[p] = true
	return removed


## 洞坐标回写 params（按 (x,y) 字典序，保证落盘稳定）。
static func _iso_holes_echo(removed: Dictionary) -> Array:
	var keys: Array = removed.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	var out: Array = []
	for k: Vector2i in keys:
		out.append({"x": k.x, "y": k.y})
	return out


## ==== (f)~(i) 四族「精确铺装」异形棋盘 ====
##
## 与 (a)~(e) 的分别：这一批的邻接**不从手写方向表来**，而是由几何反推（`build_from_cells`）——
## 拓扑与几何同源，结构上不可能脱节。判据 = **共边**（两格共享整条边 = 两个端点重合）。
## 四族都是经典一致铺装（uniform tiling），边长一致、数学上无缝无重叠：
##   · tri_grid  3.3.3.3.3.3  等边三角网格          —— 度 3（线索覆盖 3 格，极简）
##   · trihex    3.6.3.6      三角 + 六边（卡果梅）  —— 度 3 / 6（编织感）
##   · t31212    3.12.12      十二边 + 三角          —— 度 3 / 12（大格对小格，极差最大）
##   · ring      同心环盘（角向为环，可绕回）        —— 度 3~6（甜甜圈；环向首尾相接）
##
## 四族都只在**同族内**混合形状：三角网格纯三角；3.6.3.6 是三角+六边；3.12.12 是十二边+三角；
## 环盘是同形扇区。形状本身即族的身份证（与 GDD §4「形状是族的身份证」同口径）。


## 顶点量化键（1e5 分辨率）。相邻格若共享一个顶点，两侧算出的浮点必须能对到同一个键——
## 由于所有族都用**同一个公式**算共享顶点（中点 / 极坐标采样 / 沿边取 t），这是成立的。
static func _vkey(p: Vector2) -> Vector2i:
	return Vector2i(int(round(p.x * 100000.0)), int(round(p.y * 100000.0)))


## 几何驱动建图：由多边形集合反推邻接，返回 {positions, adjacency, style, params}。
## min_shared = 2 → 共边（默认，推荐）；= 1 → 共边 ∪ 共顶点（更密的邻域口径）。
## 这是「新族推荐写法」：只写几何，邻接自动与几何一致（test 会逐边复验）。
static func build_from_cells(cells_geo: Array, style: String, params: Dictionary = {},
		min_shared := 2) -> Dictionary:
	if cells_geo.is_empty():
		push_error("ShapeGenerator.build_from_cells: 格集合为空（style=%s）" % style)
		return _empty()
	# 顶点 → 拥有它的格索引
	var owners := {}
	for idx in cells_geo.size():
		var rec: Dictionary = cells_geo[idx]
		for v: Vector2 in (rec["poly"] as PackedVector2Array):
			var k := _vkey(v)
			if not owners.has(k):
				owners[k] = []
			(owners[k] as Array).append(idx)
	# 每对格共享几个顶点
	var shared := {}
	for k in owners:
		var ids: Array = owners[k]
		for a in range(ids.size()):
			for b in range(a + 1, ids.size()):
				var lo: int = mini(int(ids[a]), int(ids[b]))
				var hi: int = maxi(int(ids[a]), int(ids[b]))
				var pk := lo * 100000 + hi
				shared[pk] = int(shared.get(pk, 0)) + 1
	var positions: Array = []
	var cells := {}
	for rec2: Dictionary in cells_geo:
		var pos: Vector2i = rec2["pos"]
		if cells.has(pos):
			push_error("ShapeGenerator.build_from_cells: 格坐标重复 %s（style=%s）" % [str(pos), style])
			return _empty()
		cells[pos] = true
		positions.append({"x": pos.x, "y": pos.y})
	var seen := {}
	var adjacency: Array = []
	for pk in shared:
		if int(shared[pk]) < min_shared:
			continue
		var lo2: int = int(pk) / 100000
		var hi2: int = int(pk) % 100000
		_add_edge(cells, seen, adjacency, cells_geo[lo2]["pos"], cells_geo[hi2]["pos"])
	return {"positions": positions, "adjacency": adjacency, "style": style, "params": params}


# ---------- (f) 3.3.3.3.3.3 等边三角网格 ----------

## 等边三角网格：每个单位「菱形格」切成上下两个三角形（边长 1）。
## 奇数行错半格 ⇒ 三角形是等边的（不是直角三角）。
## 坐标：菱形格 (i,j) → 上三角 (2i, j)、下三角 (2i+1, j)。
static func tri_grid_cells_geo(cols: int, rows: int) -> Array:
	var h := 0.8660254037844386
	var out: Array = []
	for j in rows:
		for i in cols:
			var ox := float(i) + (0.5 if (j % 2) == 1 else 0.0)
			var y0 := float(j) * h
			var y1 := float(j + 1) * h
			out.append({"pos": Vector2i(i * 2, j), "poly": PackedVector2Array([
				Vector2(ox, y0), Vector2(ox + 1.0, y0), Vector2(ox + 0.5, y1)])})
			out.append({"pos": Vector2i(i * 2 + 1, j), "poly": PackedVector2Array([
				Vector2(ox + 0.5, y1), Vector2(ox + 1.5, y1), Vector2(ox + 1.0, y0)])})
	return out


static func build_tri_grid(cols: int, rows: int) -> Dictionary:
	if cols <= 0 or rows <= 0:
		push_error("ShapeGenerator.build_tri_grid: cols/rows 必须为正整数（收到 %d×%d）" % [cols, rows])
		return _empty()
	return build_from_cells(tri_grid_cells_geo(cols, rows), "tri_grid",
			{"cols": cols, "rows": rows})


# ---------- (g) 3.6.3.6 三角 + 六边（卡果梅） ----------

## 3.6.3.6：三角晶格（间距 1）的**全截角**。
##   · 每个晶格**顶点** → 一个六边形（顶点 = 该点 6 条边的中点，边长 0.5）
##   · 每个晶格**三角形** → 一个 medial 三角形（三边中点，边长 0.5）
## 两者边长相同 ⇒ 铺满。只在「6 邻全在」的顶点出六边形、只在「3 个顶点六边形都在」处出三角，
## 于是边界自然收成锯齿（不需额外裁剪规则）。
## 坐标：六边形 (2i, 2j)；三角形 (2i+1, 2j) 与 (2i+1, 2j+1)（互不冲突且非负）。
static func trihex_cells_geo(cols: int, rows: int) -> Array:
	var h := 0.8660254037844386
	var span := maxi(cols, rows) + 3
	var pt := {}
	for j in span:
		for i in span:
			pt[Vector2i(i, j)] = Vector2(float(i) + 0.5 * float(j), float(j) * h)
	var nb: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1),
			Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1)]
	var hexes := {}
	for j in span:
		for i in span:
			var key := Vector2i(i, j)
			var pts := PackedVector2Array()
			var ok := true
			for d: Vector2i in nb:
				var nk := key + d
				if not pt.has(nk):
					ok = false
					break
				pts.append(((pt[nk] as Vector2) + (pt[key] as Vector2)) * 0.5)
			if ok:
				hexes[key] = _sort_poly_ccw(pts, pt[key])
	var out: Array = []
	for key: Vector2i in hexes:
		out.append({"pos": Vector2i(key.x * 2, key.y * 2), "poly": hexes[key]})
	# 三角形：三角晶格的两个「半格」三角形（(i,j)-(i+1,j)-(i,j+1) 与 (i+1,j)-(i+1,j+1)-(i,j+1)）
	for j in span:
		for i in span:
			var pair := [[Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i, j + 1)],
					[Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]]
			for t in pair.size():
				var tri: Array = pair[t]
				var all_hex := true
				for v: Vector2i in tri:
					if not hexes.has(v):
						all_hex = false
						break
				if not all_hex:
					continue
				var tp := PackedVector2Array()
				for e in [[0, 1], [1, 2], [0, 2]]:
					tp.append(((pt[tri[e[0]]] as Vector2) + (pt[tri[e[1]]] as Vector2)) * 0.5)
				out.append({"pos": Vector2i(i * 2 + 1, j * 2 + t), "poly": _sort_poly_ccw(tp, _poly_centroid(tp))})
	return out


static func build_trihex(cols: int, rows: int) -> Dictionary:
	if cols <= 0 or rows <= 0:
		push_error("ShapeGenerator.build_trihex: cols/rows 必须为正整数（收到 %d×%d）" % [cols, rows])
		return _empty()
	var geo := trihex_cells_geo(cols, rows)
	return build_from_cells(geo, "trihex", {"cols": cols, "rows": rows})


# ---------- (h) 3.12.12 十二边 + 三角 ----------

## 3.12.12：蜂窝（六边形边长 1）的截角，截断参数 t = 2−√3（均匀铺装；
## 令三角形边长 == 十二边形边长 == 2√3−3）。
##   · 每个六边形 → 一个十二边形（6 个角各截掉 t）
##   · 每个蜂窝顶点（3 个六边形共点）→ 一个等边三角形（沿 3 条边各取 t）
## 度：十二边形 12（6 个对十二边形 + 6 个对三角形）、三角形 3 —— 全库最大的度数极差。
## 坐标：十二边形 (i, j)；三角形 (cols+3+k, 0)。
static func t31212_cells_geo(cols: int, rows: int) -> Array:
	var d := 1.7320508075688772
	var t := 2.0 - d
	var span := maxi(cols, rows) + 3
	var centers := {}
	for j in span:
		for i in span:
			centers[Vector2i(i, j)] = Vector2(d * (float(i) + 0.5 * float(j)), 1.5 * float(j))
	var out: Array = []
	for key: Vector2i in centers:
		var hx := _hexagon_pts(centers[key])
		var pts := PackedVector2Array()
		for k in 6:
			var p: Vector2 = hx[k]
			var pv: Vector2 = hx[(k + 5) % 6]
			var nx: Vector2 = hx[(k + 1) % 6]
			pts.append(p + (pv - p) * t)
			pts.append(p + (nx - p) * t)
		out.append({"pos": Vector2i(key.x, key.y), "poly": pts})
	# 蜂窝顶点 → 3 个六边形共有 → 三角形
	# vm 值存**首见浮点坐标**（代表值），量化键只作归并用 —— 三角形格心必须用
	# 六边形的**实际**共享顶点坐标，绝不能从量化键反推（k/100000 有 ≤5e-6 的
	# 网格误差，会让三角形截角与十二边形截角错开数个微单位、顶角和到不了 360°）。
	var vm := {}
	for key2: Vector2i in centers:
		for p2: Vector2 in _hexagon_pts(centers[key2]):
			var k2 := _vkey(p2)
			if not vm.has(k2):
				vm[k2] = {"v": p2, "owners": []}
			(vm[k2]["owners"] as Array).append(key2)
	var tcount := 0
	for k3 in vm:
		var rec_vm: Dictionary = vm[k3]
		var owners: Array = rec_vm["owners"]
		if owners.size() != 3:
			continue
		var v: Vector2 = rec_vm["v"]
		var nbrs: Array = []
		for o: Vector2i in owners:
			var hx2 := _hexagon_pts(centers[o])
			for k4 in 6:
				if _vkey(hx2[k4]) != k3:
					continue
				for w: Vector2 in [hx2[(k4 + 5) % 6], hx2[(k4 + 1) % 6]]:
					var dup := false
					for q: Vector2 in nbrs:
						if _vkey(q) == _vkey(w):
							dup = true
							break
					if not dup:
						nbrs.append(w)
		if nbrs.size() != 3:
			continue
		var tp := PackedVector2Array()
		for w2: Vector2 in nbrs:
			tp.append(v + (w2 - v) * t)
		out.append({"pos": Vector2i(cols + 3 + tcount, 0), "poly": _sort_poly_ccw(tp, v)})
		tcount += 1
	return out


static func build_t31212(cols: int, rows: int) -> Dictionary:
	if cols <= 0 or rows <= 0:
		push_error("ShapeGenerator.build_t31212: cols/rows 必须为正整数（收到 %d×%d）" % [cols, rows])
		return _empty()
	var geo := t31212_cells_geo(cols, rows)
	return build_from_cells(geo, "t31212", {"cols": cols, "rows": rows})


# ---------- (i) 同心环盘（角向首尾相接 = 环状拓扑） ----------

## 同心环盘：sectors[r] = 第 r 环的扇区数。**角向首尾相接**（第 n−1 与第 0 扇区相邻）⇒
## 角向是一圈闭环（拓扑上的环，不是矩形盘的直线行）。
## 弧线按**全局角度栅格**采样（step_deg），因此相邻两环共用完全相同的折线 ⇒ 零缝
## （若各环各自按自身扇区宽度采样，环与环的边界折线会错开、裂出细缝）。
## 约束：360/sectors[r] 必须是 step_deg 的整数倍（否则报错，不静默产歪盘）。
## 坐标：(扇区号 k, 环号 r)。
static func ring_cells_geo(sectors: Array, step_deg: float = 10.0,
		r0: float = 1.0, dr: float = 1.0) -> Array:
	var out: Array = []
	for r in sectors.size():
		var n := int(sectors[r])
		if n < 3:
			push_error("ShapeGenerator.ring: 第 %d 环扇区数 %d < 3（无法成环）" % [r, n])
			return []
		var width := 360.0 / float(n)
		if absf(width / step_deg - round(width / step_deg)) > 0.000001:
			push_error("ShapeGenerator.ring: 第 %d 环 %d 扇区 → 扇区宽 %.3f° 不是步长 %.1f° 的整数倍（弧线采样会对不齐 ⇒ 缝隙）" % [r, n, width, step_deg])
			return []
		var ri := r0 + float(r) * dr
		var ro := ri + dr
		for k in n:
			var a0 := float(k) * width
			var a1 := a0 + width
			var poly := _arc_pts(ri, a0, a1, step_deg)
			var outer := _arc_pts(ro, a0, a1, step_deg)
			for idx in range(outer.size() - 1, -1, -1):
				poly.append(outer[idx])
			out.append({"pos": Vector2i(k, r), "poly": poly})
	return out


static func build_ring(sectors: Array, step_deg: float = 10.0,
		r0: float = 1.0, dr: float = 1.0) -> Dictionary:
	var geo := ring_cells_geo(sectors, step_deg, r0, dr)
	if geo.is_empty():
		return _empty()
	var sec: Array = []
	for s in sectors:
		sec.append(int(s))
	return build_from_cells(geo, "ring",
			{"sectors": sec, "step_deg": step_deg, "r0": r0, "dr": dr})


## 极坐标弧采样（含两端点）：角度按全局栅格走，保证相邻环边界逐点相同。
static func _arc_pts(radius: float, a0: float, a1: float, step_deg: float) -> PackedVector2Array:
	var n := int(round((a1 - a0) / step_deg))
	var out := PackedVector2Array()
	for i in n + 1:
		var a := deg_to_rad(a0 + float(i) * step_deg)
		out.append(Vector2(radius * cos(a), radius * sin(a)))
	return out


## 正六边形 6 顶点（外接半径 1，角度 30°+60°k）。
static func _hexagon_pts(c: Vector2) -> Array:
	var out: Array = []
	for k in 6:
		var a := deg_to_rad(30.0 + 60.0 * float(k))
		out.append(c + Vector2(cos(a), sin(a)))
	return out


static func _poly_centroid(poly: PackedVector2Array) -> Vector2:
	var s := Vector2.ZERO
	for v: Vector2 in poly:
		s += v
	return s / maxf(float(poly.size()), 1.0)


## 按绕格心的角度排成逆时针（渲染用 draw_colored_polygon 要求同绕序，避免自交）。
static func _sort_poly_ccw(poly: PackedVector2Array, c: Vector2) -> PackedVector2Array:
	var arr: Array = []
	for v: Vector2 in poly:
		arr.append(v)
	arr.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return atan2(a.y - c.y, a.x - c.x) < atan2(b.y - c.y, b.x - c.x))
	var out := PackedVector2Array()
	for v2: Vector2 in arr:
		out.append(v2)
	return out


## 便利入口（供上层接线用）：按 kind + params 直接产出可用的 AdjacencyGrid。
## kind / params：
##   "holed_grid" —— {"rows":R, "cols":C, "holes":[...]}（holes 可省）
##   "hex"        —— {"size":N}
##   "t488"       —— {"size":N}
##   "iso_cubes"  —— {"cols":C, "rows":R, "holes":[...]}（等轴菱面；holes 可省）
##   "tri_grid"   —— {"cols":C, "rows":R}（等边三角网格；共 2CR 个三角形）
##   "trihex"     —— {"cols":C, "rows":R}（3.6.3.6 三角+六边）
##   "t31212"     —— {"cols":C, "rows":R}（3.12.12 十二边+三角）
##   "ring"       —— {"sectors":[n0,n1,...]}（同心环盘；可选 step_deg/r0/dr）
##   "mask"       —— {"style":S, "mask":[...]}（S ∈ holed_grid/hex/t488；mask = build_from_mask
##                    的 ASCII 轮廓；落盘 params = {"mask": mask}，供 JSON 审计）
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
		"tri_grid":
			topo = build_tri_grid(int(params.get("cols", 0)), int(params.get("rows", 0)))
		"trihex":
			topo = build_trihex(int(params.get("cols", 0)), int(params.get("rows", 0)))
		"t31212":
			topo = build_t31212(int(params.get("cols", 0)), int(params.get("rows", 0)))
		"ring":
			topo = build_ring(params.get("sectors", []), float(params.get("step_deg", 10.0)),
					float(params.get("r0", 1.0)), float(params.get("dr", 1.0)))
		"iso_cubes":
			topo = build_iso_cubes(int(params.get("cols", 0)), int(params.get("rows", 0)),
					params.get("holes", []))
		"mask":
			# mask 族（T7）：style + mask 两个字段 → build_from_mask；落盘 params = {"mask": mask}
			# 让产物 JSON 自带图案审计（人可读、可复核）。
			var mask_v: Variant = params.get("mask", [])
			if not (mask_v is Array):
				push_error("ShapeGenerator.to_adjacency_grid: mask 必须是字符串数组（收到 %s）" % str(mask_v))
				return null
			var mask_arr: Array = mask_v
			topo = build_from_mask(str(params.get("style", "")), mask_arr, {"mask": mask_arr})
		_:
			push_error("ShapeGenerator.to_adjacency_grid: 未注册的形状 kind \"%s\"（可用：holed_grid/hex/t488/iso_cubes/tri_grid/trihex/t31212/ring/mask）" % kind)
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
##
## L1 交叉说明（2026-09-21）：全仓有**三处**「无向边去重」的独立实现——本函数、
## core/puzzle_generator.gd 的 `_topology_to_dict`、core/adjacency_grid.gd 的 `normalized`。
## 三者**集合语义同口径**（同一无向边只存一条），但输出定向不同（本函数按字典序 (lo,hi)；
## 另两处按遍历序 (p, nb)）。「落盘边数 == 运行时边数」由集合语义保证（test_shape_levels 有断言）；
## **不要**断言两条路径的 adjacency 数组逐字节一致（顺序本就不同）。
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
