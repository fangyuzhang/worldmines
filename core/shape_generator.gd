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
#   (j)~(l) build_circle / build_star / build_sector —— 参数化轮廓族：圆 / 星形 / 扇形（整数格
#       栅格化；与 (a)~(i) **同一接口**，见文件后段「(j)~(l) 参数化轮廓族」一节）。
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
## (m)~(n) 栅格化三档精度：**边界判定的采样严格度**（与 `precision`（内接多边形边数）是两个正交旋钮）。
##   coarse  —— 严格内缩：格心 + 四角**全部**落在形状内才收录（格数最少）；
##   default —— **硬红线：逐格与旧行为完全一致**（= 既有 `_rasterize_polygon` 的"只判格心"口径）；
##   fine    —— 宽松外扩：格心 / 四角 / 四边中点**任一点**落在形状内即收录（格数最多）。
## 严格单调（coarse < default < fine）与包含关系（粗 ⊆ 默认 ⊆ 细）由 test_core_shape_geometry 断言 —— 防空转。
const RASTER_COARSE := "coarse"
const RASTER_DEFAULT := "default"
const RASTER_FINE := "fine"
const RASTER_TIERS: Array[String] = [RASTER_COARSE, RASTER_DEFAULT, RASTER_FINE]


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
	var half := floori((size - 1) / 2.0)   # A8：int/int 显式化
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
		var lo2: int = floori(int(pk) / 100000.0)   # A8：int/int 显式化（pk 打包值恒 ≥0）
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


## ==== (j)~(l) 参数化轮廓族：圆 / 星形 / 扇形 ====
##
## 接口与 (a)~(i) 完全一致：`build_*(...) -> {positions, adjacency, style, params}`，
## 参数非法一律 push_error + 空拓扑（不静默产半成品），`style`/`params` 同为展示用字段。
## 邻接复用 `_graph_from_dirs(cells, MOORE8)`：与 holed_grid 同为 Moore 8 邻（即
## `grid_interface.gd` 的 8 邻域口径），故既有不变量（非负 / 对称 / 无自环 / 无重复 / 端点闭合）
## 原样成立——**本段不碰既有 9 族任何一行**。
##
## 栅格化口径（坐标离散化）：格 = **整数** (x, y)，格心即该整数点（x = 列、y = 行）。
## 圆心 / 星心 / 扇形顶点一律取 (radius, radius) ⇒ 整个形状落在 [0, 2*radius]² 内，
## 坐标天然非负（board.gd 直接 setup_from_topo、不做 normalized，负坐标会让 CP-SAT 索引越界）。
##
## 数据爆炸闸门（文档 A/C 类）：**生成前**先用闭式上界估算格数，再交
## `EditorDoc.check_cell_budget()`（DEFAULT 500 / MAX 5000 两档，单一真源——本模块只读不改）。
## 估算取上界而非精确值（与 `EditorDoc.estimate_cells` 同性质）：宁可在门槛附近保守拒绝，
## 也绝不先把超大格集建出来再判。超 MAX ⇒ 拒绝生成，原因同时写进 `error` 字段与 push_error。


## (j) 圆：以 (radius, radius) 为心、radius 为半径的**内接正 precision 边形**在整数格上栅格化。
##
## 为什么是"内接正 n 边形"而不是直接判 dist ≤ radius：`precision` 就是精度旋钮（边数越多越接近
## 正圆），内接保证形状恒在半径内、格集随 precision 单调收敛，且与 (k)/(l) 共用同一套多边形判据。
## 参数：radius ≥ 1（整数，格为单位）；precision ≥ 3（内接边形边数，默认 24）；
##       tier = 栅格化精度档（见 RASTER_TIERS；默认档与旧行为逐格一致）。
static func build_circle(radius: int, precision: int = 24, tier := RASTER_DEFAULT) -> Dictionary:
	if not RASTER_TIERS.has(tier):
		return _reject("build_circle", "tier 必须是 %s 之一（收到 \"%s\"）" % [str(RASTER_TIERS), str(tier)])
	if radius <= 0:
		return _reject("build_circle", "radius 必须为正整数（收到 %d）：半径以格为单位，须 ≥ 1" % radius)
	if precision < 3:
		return _reject("build_circle", "precision 必须 ≥ 3（收到 %d）：圆按内接正 precision 边形栅格化" % precision)
	var why := _budget_reason(_disk_upper_bound(float(radius)))
	if why != "":
		return _reject("build_circle", why)
	var c := Vector2(float(radius), float(radius))
	var poly := _regular_polygon_pts(c, float(radius), precision, -90.0)
	var params := {"radius": radius, "precision": precision}
	# 默认档不写 tier ⇒ 既有产物的 params 逐字段零变化（硬红线：默认档 == 旧行为）。
	if tier != RASTER_DEFAULT:
		params["tier"] = tier
	return _outline_topo(_rasterize_polygon(poly, tier), "circle", params)


## (k) 星形：points 个角（= 2*points 个顶点的星形多边形）在整数格上栅格化。
##
## 顶点从正上方（-90°）起、外半径 / 内半径交替 ⇒ 角数恒为 points（test 逐角复核）。
## 参数：points ≥ 3（角数）；outer_radius ≥ 1（外半径，格）；inner_ratio ∈ (0,1)（内/外半径比）。
static func build_star(points: int, outer_radius: int, inner_ratio: float = 0.5) -> Dictionary:
	if points < 3:
		return _reject("build_star", "points（角数）必须 ≥ 3（收到 %d）：不足 3 角不成星形" % points)
	if outer_radius <= 0:
		return _reject("build_star", "outer_radius 必须为正整数（收到 %d）：外半径以格为单位，须 ≥ 1" % outer_radius)
	if not is_finite(inner_ratio) or inner_ratio <= 0.0 or inner_ratio >= 1.0:
		return _reject("build_star", "inner_ratio（内/外半径比）必须是 (0,1) 内的有限数（收到 %s）" % str(inner_ratio))
	var why := _budget_reason(_disk_upper_bound(float(outer_radius)))
	if why != "":
		return _reject("build_star", why)
	var c := Vector2(float(outer_radius), float(outer_radius))
	var poly := _star_polygon_pts(c, float(outer_radius), inner_ratio, points)
	return _outline_topo(_rasterize_polygon(poly), "star",
			{"points": points, "outer_radius": outer_radius, "inner_ratio": inner_ratio})


## (l) 扇形：以 (radius, radius) 为顶点、张角 [start_deg, end_deg]、半径 radius 的楔形。
##
## 判据 = 精确极坐标（dist ≤ radius 且 start_deg ≤ 角度 ≤ end_deg），顶点格（dist = 0）恒含
## （顶点处角度未定义，但它就是扇形本身的尖角）。角度口径与屏幕行坐标一致：
## 0° = +x 方向、向 +y（行向下）为正。范围须满足 0 ≤ start_deg < end_deg ≤ 360（不跨 0°）。
static func build_sector(radius: int, start_deg: float, end_deg: float) -> Dictionary:
	if radius <= 0:
		return _reject("build_sector", "radius 必须为正整数（收到 %d）：半径以格为单位，须 ≥ 1" % radius)
	if not is_finite(start_deg) or not is_finite(end_deg):
		return _reject("build_sector", "start_deg / end_deg 必须是有限数（收到 %s / %s）" % [str(start_deg), str(end_deg)])
	if start_deg < 0.0 or end_deg > 360.0 or start_deg >= end_deg:
		return _reject("build_sector", "角度范围须满足 0 ≤ start_deg < end_deg ≤ 360（收到 %s → %s）" % [str(start_deg), str(end_deg)])
	var why := _budget_reason(_disk_upper_bound(float(radius)) * (end_deg - start_deg) / 360.0)
	if why != "":
		return _reject("build_sector", why)
	var c := Vector2(float(radius), float(radius))
	var box := _verts_bbox(_sector_scan_verts(c, float(radius), start_deg, end_deg), 1)
	var cells := {}
	for y in range(box.position.y, box.end.y):
		for x in range(box.position.x, box.end.x):
			if _sector_contains(c, float(radius), start_deg, end_deg, Vector2(float(x), float(y))):
				cells[Vector2i(x, y)] = true
	return _outline_topo(cells, "sector", {"radius": radius, "start_deg": start_deg, "end_deg": end_deg})


## ==== (m) 正 N 边形（ngon）与 (n) 环形（annulus）====
##
## 补齐 `core/shape_dag.gd` 词汇表 `PRIMITIVE_SHAPES` 里两个**曾自记"本仓无生成器"**的名字：
##   · "ngon" —— 正 N 边形（该文件 :276 原文："本仓未提供正 N 边形构建器（无 build_ngon）"）；
##   · "ring" —— 该文件 :273 明确其语义是 **annulus**（单个内圆挖空的带洞形状），并禁止拿
##     既有 `build_ring`（同心环盘）顶替 ⇒ 这里落地的就是 annulus（`build_annulus`），
##     **不是**环盘。两者同名不同义，别再混。
## 三族（circle / ngon / annulus）同接口同口径：入参风格一致（整数半径 + 可选 precision + tier），
## 返回同一套 `{positions, adjacency, style, params}`；邻接复用 `_graph_from_dirs(..., MOORE8)`，
## 故既有不变量（非负 / 对称 / 无自环 / 无重复 / 端点闭合）原样成立——**本段不碰既有族任何一行**。


## (m) 正 N 边形：边数 sides（≥3）、外接半径 radius 的正多边形在整数格上栅格化。
##
## 与 (j) 圆同族同口径（同样以 (radius, radius) 为心、从正上方 -90° 起、Moore 8 邻），
## 差别只在**几何是精确多边形**（无内接近似误差）——圆是它的极限特例。
## 参数：sides ≥ 3（边数）；radius ≥ 1（外接半径，格）；tier = 栅格化精度档（见 RASTER_TIERS）。
static func build_ngon(sides: int, radius: int, tier := RASTER_DEFAULT) -> Dictionary:
	if not RASTER_TIERS.has(tier):
		return _reject("build_ngon", "tier 必须是 %s 之一（收到 \"%s\"）" % [str(RASTER_TIERS), str(tier)])
	if sides < 3:
		return _reject("build_ngon", "sides（边数）必须 ≥ 3（收到 %d）：不足 3 边不成多边形" % sides)
	if radius <= 0:
		return _reject("build_ngon", "radius 必须为正整数（收到 %d）：外接半径以格为单位，须 ≥ 1" % radius)
	var why := _budget_reason(_disk_upper_bound(float(radius)))
	if why != "":
		return _reject("build_ngon", why)
	var c := Vector2(float(radius), float(radius))
	var poly := _regular_polygon_pts(c, float(radius), sides, -90.0)
	var params := {"sides": sides, "radius": radius}
	if tier != RASTER_DEFAULT:
		params["tier"] = tier
	return _outline_topo(_rasterize_polygon(poly, tier), "ngon", params)


## (n) 环形 annulus：外半径 outer_radius、内半径 inner_radius（内圆挖空）的**带洞**圆环。
##
## 几何 = 外圆盘 − 内圆盘：两条内接正 precision 边形的边界合成一个"甜甜圈"多边形（外环 + 反向内环），
## 由 `_poly_contains` 的**奇偶判据**处理 ⇒ 洞内格天然不被收录（不是靠包围盒挖洞）。
## 参数：outer_radius ≥ 1；1 ≤ inner_radius < outer_radius；precision ≥ 3；tier = 栅格化精度档。
static func build_annulus(outer_radius: int, inner_radius: int,
		precision: int = 24, tier := RASTER_DEFAULT) -> Dictionary:
	if not RASTER_TIERS.has(tier):
		return _reject("build_annulus", "tier 必须是 %s 之一（收到 \"%s\"）" % [str(RASTER_TIERS), str(tier)])
	if outer_radius <= 0:
		return _reject("build_annulus", "outer_radius 必须为正整数（收到 %d）：以格为单位，须 ≥ 1" % outer_radius)
	if inner_radius < 1 or inner_radius >= outer_radius:
		return _reject("build_annulus", "inner_radius 必须满足 1 ≤ inner_radius < outer_radius（收到 inner=%d, outer=%d）：否则不是「带洞的环」而是整盘或空盘" % [inner_radius, outer_radius])
	if precision < 3:
		return _reject("build_annulus", "precision 必须 ≥ 3（收到 %d）：内外圆均按内接正 precision 边形栅格化" % precision)
	var why := _budget_reason(_disk_upper_bound(float(outer_radius)))
	if why != "":
		return _reject("build_annulus", why)
	var c := Vector2(float(outer_radius), float(outer_radius))
	var poly := _regular_polygon_pts(c, float(outer_radius), precision, -90.0)
	var inner := _regular_polygon_pts(c, float(inner_radius), precision, -90.0)
	for idx in range(inner.size() - 1, -1, -1):   # 内环反向：形成规范"甜甜圈"环序（奇偶判据下等价）
		poly.append(inner[idx])
	var params := {"outer_radius": outer_radius, "inner_radius": inner_radius, "precision": precision}
	if tier != RASTER_DEFAULT:
		params["tier"] = tier
	return _outline_topo(_rasterize_polygon(poly, tier), "annulus", params)


# ---------- (o) 边缘平滑：腐蚀 / 膨胀（格集 × 网格 → 格集） ----------
#
# 纯函数：不建盘、不改网格、不引用 UI/autoload。判界**一律问网格** `grid.in_board()` /
# `grid.get_neighbors()`，**绝不**用 cols/rows 包围盒 —— 形状盘（环形 annulus / 挖洞盘）的洞格
# 不在盘上（没有 Cell），按包围盒补洞会把格写进洞里：渲染找不到 Cell、CP-SAT 索引也会错位。
#
# 语义（在网格自己的邻域上做形态学，矩形盘即 Moore 8 邻、蜂窝盘即 6 邻、环盘即环向 + 径向）：
#   · 膨胀 dilate：格集 ∪ 其全部**盘内**邻格（洞格 / 盘外格永不被写入——它们不在邻域里）。
#   · 腐蚀 erode ：格集里「盘内全部邻格也都在集内」的格（外缩、抹掉薄突刺）。
# 输入里的盘外 / 洞格条目一律**丢弃**（"不存在的格"不是数据错误，不报错也不写入）。

## 膨胀：格集每个格 + 其全部盘内邻格并入结果。返回**新**格集（Dictionary[Vector2i -> true]）。
static func dilate_cells(cells: Dictionary, grid: GridInterface) -> Dictionary:
	var out := {}
	if grid == null:
		push_error("ShapeGenerator.dilate_cells: grid 为空（判界必须走网格 in_board()/get_neighbors()，不得按包围盒）")
		return out
	for p: Vector2i in cells:
		if not grid.in_board(p):
			continue                      # 洞格 / 盘外格：不存在，丢弃（绝不写入）
		out[p] = true
		for nb: Vector2i in grid.get_neighbors(p):
			if grid.in_board(nb):
				out[nb] = true
	return out


## 腐蚀：只保留「自身与**全部盘内邻格**都在集内」的格。孤立格（盘内无邻格）恒保留：
## 其邻域为空集，"全部邻格都在集内"空洞成立（否则单格盘会被腐蚀成空盘）。
static func erode_cells(cells: Dictionary, grid: GridInterface) -> Dictionary:
	var out := {}
	if grid == null:
		push_error("ShapeGenerator.erode_cells: grid 为空（判界必须走网格 in_board()/get_neighbors()，不得按包围盒）")
		return out
	for p: Vector2i in cells:
		if not grid.in_board(p):
			continue
		var keep := true
		for nb: Vector2i in grid.get_neighbors(p):
			if not cells.has(nb):
				keep = false
				break
		if keep:
			out[p] = true
	return out


# ---------- (j)~(l) 栅格化与闸门内部实现 ----------

## 圆盘格数的闭式上界：整数点在半径 R 的圆盘内 ⇒ 以每点为中心的单位方格之并 ⊆ 半径 R+0.5 的圆盘
## ⇒ 点数 ≤ π(R+0.5)² < π(R+1)²。再 +1 兜住取整。返回 float——调用方先比阈值再取整，
## 避免荒谬半径下 float→int 溢出把"超限"反转成"通过"。
static func _disk_upper_bound(radius: float) -> float:
	return PI * (radius + 1.0) * (radius + 1.0) + 1.0


## 预算闸门：**直接复用** `EditorDoc.check_cell_budget` 的两档口径（单一真源，勿在此另立魔数）。
## 返回 "" = 放行（含 warn 档：照做但应提示）；否则返回可读原因（block 档）。先钳到 int64 安全区防溢出。
static func _budget_reason(estimate: float) -> String:
	var est := int(clampf(estimate, 0.0, 9.0e18))
	var rep: Dictionary = EditorDoc.check_cell_budget(est)
	if bool(rep.get("ok", true)):
		return ""
	return str(rep.get("reason", ""))


## 拒绝生成的统一返回：空 positions/adjacency + `error` 可读原因（push_error 同步写控制台）。
## 与既有族的 `_empty()` 相比多带 `error` ⇒「为什么被拒」可被程序读取（测试 / UI 都能取）。
static func _reject(label: String, reason: String) -> Dictionary:
	push_error("ShapeGenerator.%s: %s" % [label, reason])
	return {"positions": [], "adjacency": [], "error": reason}


## 格集 → 拓扑（Moore 8 邻，与 holed_grid 同款）+ 展示用 style/params。三族共用。
static func _outline_topo(cells: Dictionary, style: String, params: Dictionary) -> Dictionary:
	var topo := _graph_from_dirs(cells, MOORE8)
	topo["style"] = style
	topo["params"] = params
	return topo


## 顶点集的整数扫描窗（floor/ceil ± margin）。margin ≥ 1 兜住弧线在采样点之间的凸出。
static func _verts_bbox(verts: PackedVector2Array, margin: int) -> Rect2i:
	if verts.is_empty():
		return Rect2i(0, 0, 0, 0)
	var min_x := 1 << 30
	var min_y := 1 << 30
	var max_x := -(1 << 30)
	var max_y := -(1 << 30)
	for v: Vector2 in verts:
		min_x = mini(min_x, floori(v.x) - margin)
		min_y = mini(min_y, floori(v.y) - margin)
		max_x = maxi(max_x, ceili(v.x) + margin)
		max_y = maxi(max_y, ceili(v.y) + margin)
	return Rect2i(Vector2i(min_x, min_y), Vector2i(max_x - min_x + 1, max_y - min_y + 1))


## 多边形 → 格集（射线 / 奇偶判据，凹凸皆可；**带洞**多边形同样成立）。
## tier = 三档采样严格度（见 RASTER_TIERS）：default 只判格心 ⇒ 与旧实现逐格、逐次序完全一致
## （硬红线）；coarse 要求四角全中（内缩）；fine 任一边界采样点命中即收（外扩）。
## 采样点都是**格内**坐标、判界只看多边形本身 ⇒ 有洞的形状绝不会被包围盒补洞。
static func _rasterize_polygon(poly: PackedVector2Array, tier := RASTER_DEFAULT) -> Dictionary:
	var box := _verts_bbox(poly, 1)
	var cells := {}
	for y in range(box.position.y, box.end.y):
		for x in range(box.position.x, box.end.x):
			if _sample_hits(poly, x, y, tier):
				cells[Vector2i(x, y)] = true
	return cells


## 单格采样点集（相对格心；格边长 = 1）。未知 tier 退回 default（调用方须先校验 tier）。
static func _cell_samples(tier: String) -> Array[Vector2]:
	var out: Array[Vector2] = []
	match tier:
		RASTER_COARSE:
			out.assign([Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(-0.5, 0.5), Vector2(0.5, 0.5)])
		RASTER_FINE:
			out.assign([Vector2.ZERO,
					Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(-0.5, 0.5), Vector2(0.5, 0.5),
					Vector2(-0.5, 0.0), Vector2(0.5, 0.0), Vector2(0.0, -0.5), Vector2(0.0, 0.5)])
		_:
			out.assign([Vector2.ZERO])
	return out


## 采样判据：coarse = **全部**采样点命中；default / fine = **任一**采样点命中。
static func _sample_hits(poly: PackedVector2Array, x: int, y: int, tier: String) -> bool:
	var strict := tier == RASTER_COARSE
	for s: Vector2 in _cell_samples(tier):
		var hit := _poly_contains(poly, Vector2(float(x), float(y)) + s)
		if strict and not hit:
			return false
		if not strict and hit:
			return true
	return strict


## 点是否在多边形内（射线法 / 奇偶规则）。边界点的判定不影响栅格化（两侧口径都合法）。
static func _poly_contains(poly: PackedVector2Array, p: Vector2) -> bool:
	var inside := false
	var n := poly.size()
	var j := n - 1
	for i in n:
		var pi: Vector2 = poly[i]
		var pj: Vector2 = poly[j]
		if (pi.y > p.y) != (pj.y > p.y):
			var den := pj.y - pi.y
			if is_zero_approx(den):
				den = 1e-9
			if p.x < (pj.x - pi.x) * (p.y - pi.y) / den + pi.x:
				inside = not inside
		j = i
	return inside


## 正 n 边形顶点（外接半径 radius，起始角 start_deg，逆时针）。
static func _regular_polygon_pts(c: Vector2, radius: float, n: int, start_deg: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in n:
		var a := deg_to_rad(start_deg + 360.0 * float(k) / float(n))
		out.append(c + Vector2(radius * cos(a), radius * sin(a)))
	return out


## 星形多边形顶点：2*points 个，外/内半径交替，起始角 -90°（正上方一个尖角）。
static func _star_polygon_pts(c: Vector2, outer: float, inner_ratio: float, points: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var inner := outer * inner_ratio
	for k in points * 2:
		var r := outer if (k % 2) == 0 else inner
		var a := deg_to_rad(-90.0 + 360.0 * float(k) / float(points * 2))
		out.append(c + Vector2(r * cos(a), r * sin(a)))
	return out


## 扇形扫描窗的顶点（顶点 + 弧上每 1° 采样 + 两端点）：窄扇形不会退化成扫整个方阵。
static func _sector_scan_verts(c: Vector2, radius: float, a0: float, a1: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.append(c)
	var steps := ceili(a1 - a0) + 1
	for i in steps + 1:
		var a := minf(a0 + float(i), a1)
		var rad := deg_to_rad(a)
		out.append(c + Vector2(radius * cos(rad), radius * sin(rad)))
	return out


## 扇形判据：dist ≤ radius 且角度落在 [a0, a1]；顶点格（dist = 0）恒含。
static func _sector_contains(c: Vector2, radius: float, a0: float, a1: float, p: Vector2) -> bool:
	var d := p - c
	var d2 := d.length_squared()
	if d2 <= 0.0:
		return true
	if d2 > radius * radius:
		return false
	var ang := _angle_deg(d)
	return ang >= a0 and ang <= a1


## 向量角度：0° = +x，向 +y（行方向，屏幕向下）为正，归一到 [0,360)。
static func _angle_deg(d: Vector2) -> float:
	return fposmod(rad_to_deg(atan2(d.y, d.x)), 360.0)


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
##   "circle"     —— {"radius":R, "precision":N}（圆；(j) 参数化轮廓族，precision 可省默认 24）
##   "star"       —— {"points":K, "outer_radius":R, "inner_ratio":q}（星形；(k) 参数化轮廓族）
##   "sector"     —— {"radius":R, "start_deg":a0, "end_deg":a1}（扇形；(l) 参数化轮廓族）
##   "ngon"       —— {"sides":K, "radius":R}（正 K 边形；(m) 参数化轮廓族；可选 tier）
##   "annulus"    —— {"outer_radius":R, "inner_radius":r, "precision":N}（环形 annulus（内圆挖空）；
##                    (n) 参数化轮廓族；precision 可省默认 24，可选 tier）
##   "mask"       —— {"style":S, "mask":[...]}（S ∈ holed_grid/hex/t488；mask = build_from_mask
##                    的 ASCII 轮廓；落盘 params = {"mask": mask}，供 JSON 审计）
## ⚠ **这就是上面 (m)/(n) 的"正确落点"**：DAG（ShapeDag）的 primitive "ring" = annulus（内圆挖空），
##   而本入口的 kind "ring" = **同心环盘**（多格 + 角向闭环，参数 sectors/step_deg/r0/dr）——**同名不同义**。
##   调用方必须按自己的命名空间传 kind：拿 DAG 的 shape 名直接喂本函数就会撞名、静默产出错几何。
## 形状为空、参数非法（build_* 已 push_error）、kind 未注册 → push_error 并返回 null
## （调用方据此回退矩形/报错；返回 null 而非空 grid，避免「空盘」被误当成合法关卡）。
## **绝不静默兜底**：没有"默认分支画方阵/环盘"这种路径 —— `_:` 分支只 push_error + null（见文件尾）。
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
		"circle":
			# (j) 圆：precision 可省，缺省 24（与 build_circle 的签名默认一致）。
			topo = build_circle(int(params.get("radius", 0)), int(params.get("precision", 24)))
		"star":
			# (k) 星形：inner_ratio 可省，缺省 0.5（与 build_star 的签名默认一致）。
			topo = build_star(int(params.get("points", 0)), int(params.get("outer_radius", 0)),
					float(params.get("inner_ratio", 0.5)))
		"sector":
			# (l) 扇形：角度缺省 start=0 / end=90（缺参数时 start>=end，build_sector 会给可读 error）。
			topo = build_sector(int(params.get("radius", 0)),
					float(params.get("start_deg", 0.0)), float(params.get("end_deg", 90.0)))
		"ngon":
			# (m) 正 N 边形：tier 可省，缺省 default（与 build_ngon 的签名默认一致）。
			topo = build_ngon(int(params.get("sides", 0)), int(params.get("radius", 0)),
					str(params.get("tier", RASTER_DEFAULT)))
		"annulus":
			# (n) 环形 annulus：precision 可省默认 24、tier 可省默认 default（与 build_annulus 签名一致）。
			# ⚠ 与上面的 "ring"（同心环盘）**同名不同义**，两者参数名也完全不同（这里是 outer/inner_radius）。
			topo = build_annulus(int(params.get("outer_radius", 0)), int(params.get("inner_radius", 0)),
					int(params.get("precision", 24)), str(params.get("tier", RASTER_DEFAULT)))
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
			# 显式失败（**唯一的兜底**）：不注册就报错 + null，绝不"就近挑一个盘画出来"。
			# 这里刻意不写任何默认几何 —— 历史上"默认分支画方阵/环盘"正是静默错几何的根源。
			push_error("ShapeGenerator.to_adjacency_grid: 未注册的形状 kind \"%s\"（可用：holed_grid/hex/t488/iso_cubes/tri_grid/trihex/t31212/ring/ngon/annulus/circle/star/sector/mask）" % kind)
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
