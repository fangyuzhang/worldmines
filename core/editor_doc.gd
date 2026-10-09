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
## 【部分识别的容器：custom / size】顶层未知字段进 `passthrough`，但 `custom` 与 `size` 是
## **部分识别**的容器——本模型只认其中若干子键（清单见 `CUSTOM_KNOWN_KEYS` / `SIZE_KNOWN_KEYS`），
## 其余子键分别进 `custom_passthrough` / `_size_extras`，导出时原样写回。
## 【为什么必须这样】此前 `custom` 在 `load_from()` 里是**从 `{}` 重建**的 ⇒ Mod 自定义字段
##（如 `custom.mega_cells` 之外的键）与"将来新增的字段"会在**打开→另存一次后静默消失**，
## 与「只增不改不删字段」的格式纪律直接冲突。**重建部分识别的容器 = 必然丢键**，勿改回。
##
## 【关卡内容 vs 会话选择】`mega_cells`（MegaCell）与 `dominoes`（DominoModel）是**关卡内容**：
## 与雷位同桶——随文档存/读，`load_from` **不**清空它们（只有 `shape_kind/shape_params` 等
## 会话编辑选择才清零）。骨牌在 JSON 里用生成器/Board 的 `[[{c,r},…]]` 口径，坐标换算
##（`c=x, r=y`）只发生在本文件的 `dominoes_from_level()` / `dominoes_to_level()` 两个桥函数里。
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

## `custom` / `size` 两个**部分识别**容器里本模型认识的子键；其余子键一律原样带回。
## 集中声明在此，避免"清点未知键处"与"写回处"两份清单各自漂移（漂移的下场就是静默丢键）。
##
## ⚠ `schema_id` **刻意不在此清单**：它同时是 `LevelCustomSchema` 用来选取 Mod 自定义校验器的键
##（`core/level_custom_schema.gd`：形如 `workshop.2e@1.0/schema.json`，设计文档 §3.2 的 custom 预留位）。
## 编辑器只在**自己写了 spec** 时把 `schema_id` 覆盖成 `SCHEMA_ID`（文档口径不变）；
## 没有 spec 时（别人的 Mod 关卡）必须原样带回 —— 否则"打开→另存"会把 Mod 的 schema 引用连同其
## custom 负载一起废掉（键还在、指向却没了）。
const CUSTOM_KNOWN_KEYS := ["spec", "warp_points", "regions", "mega_cells"]
const SIZE_KNOWN_KEYS := ["rows", "cols"]

# ==================== 格子数双档预算（事前估算 + 操作前硬阻，2026-10-03）====================
#
# 【为什么需要】此前"格数超限"**只在 validate() 里报错**——也就是等用户把盘建出来之后才发现；
# 而建盘本身不便宜（64x64 环绕盘 `WrapTopology.build` ≈49ms、`setup_from_topo` ≈92ms，
# 见 `struct_signature` 的实测注释），"随机布雷 / 换形状 / 改尺寸"会先把盘建出来再报错，用户白等一场。
# 所以补一层**纯计算、不建盘**的事前估算：动手前先算格数，超了就直接不执行。
#
# 【三个数字的关系（勿混淆，本次不改小任何一个既有限制）】
#   · DEFAULT_CELL_BUDGET = 500 —— 常规编辑的**软预算**（warn 阈值）。依据：本仓主流关卡是
#     9x9=81 ~ 16x16=256；500 ≈ 22x22，已覆盖"大号变体"。估算 > 它 ⇒ level="warn"（照做但提示）。
#   · MAX_CELL_BUDGET = 5000 —— 用户可把预算**调到**的最高档，也是**硬阻**阈值：
#     估算 > 它 ⇒ level="block"（不执行）。它刻意 ≥ 既有单档实上限，保证"警告档"能覆盖到上限。
#   · `MAX_CELLS`（= `WrapTopology.MAX_CELLS` = 4096）—— **加载器/拓扑的现存硬上限，本次不动**。
#     关系：估算落在 (4096, 5000] 时本层只给 warn/ok（不误伤），但 `validate()` / `WrapTopology`
#     仍会按 4096 报"格数超限"——即"预算"管编辑体验，"实数上限"管正确性，两者各司其职、都不隐藏。
const DEFAULT_CELL_BUDGET := 500
const MAX_CELL_BUDGET := 5000

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

# —— 关卡内容：复合格 / 骨牌划分（**随文档存**，不是会话编辑选择）——
#
# 【为什么是独立字段而非派生量】复合格（`MegaCell`）与骨牌划分（`DominoModel`）都是**关卡内容**：
# 与雷位/障碍同桶——会被落盘、被 Board 读走（`Board.load_level` 读顶层 `dominoes`），
# 所以必须随文档往返，**不能**像 `shape_kind/shape_params` 那样在 `load_from` 里被清零（见 `load_from` 注释）。
#
# 【落盘位置】`dominoes` 写**关卡顶层** `[[{c,r},{c,r}], …]`（`Board._parse_dominoes` 直接认）；
# `mega_cells` 写 `custom.mega_cells`（`MegaCell.to_dict()` 原文）——Board 不读它，放 custom 不污染关卡主字段。
var mega_cells: MegaCell = MegaCell.new()
var dominoes: DominoModel = DominoModel.new()

# —— 缓存（键 = struct_signature()，见其注释；内容变则签名变，缓存自动失效）——
var _topo_cache: Dictionary = {}
var _topo_sig := ""
var _grid_cache: GridInterface = null
var _grid_sig := ""
## 未挖洞「盘空间」的网格缓存（见 space_grid()；与 grid() 各自一份，互不覆盖）。
var _space_cache: GridInterface = null
var _space_sig := ""
var _audit_sig := ""
var _audit_errors: Array = []
var _audit_warnings: Array = []

# —— 无损往返 ——
var passthrough: Dictionary = {}        # 本模型不认识的关卡字段，导出时原样写回
var custom_passthrough: Dictionary = {} # 本模型不认识的 `custom.*` 子键（Mod 字段 / 未来字段），导出时原样写回
var _size_extras: Dictionary = {}       # `size` 里本模型不认识的子键（如额外维度），导出时原样写回
var _revealed_extras: Array = []       # 带 interval（遮蔽区间）的 revealed 条目：不编辑，原样写回
var _revealed_merge: Dictionary = {}   # Vector2i -> 带附加键的 revealed 原文：导出时合并回同一条

# —— 已知且**本轮接受**的丢键（留痕，别靠考古；要支持时照下面这条路线走）——
# 上面 `passthrough` / `custom_passthrough` / `_size_extras` 已覆盖容器级未知键；下面三类**仍会丢**：
#   · `topology` 的额外顶层键（仅"带 `editor` 元数据"的拓扑）：`_build_topology()` 走
#     `WrapTopology.build` **整块重生**（positions/neighbors/style/editor）⇒ 其余键丢。
#     为何不动：拓扑是**派生数据**（结构一变就该重算），而外部/形状拓扑已由 `foreign_topology`
#     原样保留 ⇒ 影响面只剩"手写 editor 元数据 + 额外键"，可接受。
#     将来支持 ⇒ `load_from` 存"非派生键原件"，在 `_level_dict()` 的 `out["topology"]` 上合并；
#     **切勿**把 positions/neighbors/editor 也带回来（那会造假真源）。
#   · `mines` / `warp_points` 的**条目级**附加键（如 `{"r":0,"c":0,"note":"x"}` 的 `note`）：
#     `_parse_cells()` 只保留 c/r（它在解析热路径上，动它风险 > 收益）。
#   · `dominoes` 的**每格**附加键：坐标桥 `_level_pair_to_xy()` / `dominoes_to_level()` 只保留 c/r
#     （与 `Board._parse_dominoes` 同口径）。
#     后两者为何不动：属**被编辑内容**（条目会被编辑器增删/重建），模型没有 per-cell 槽位；
#     且本仓现无任何产出方写这类键 ⇒ 记为"接受风险"。
#     将来支持 ⇒ 照 `revealed` 现成的 `_revealed_merge` 范式：按格记原文 + 导出时**合并回同一条**
#     （切勿整条另存 ⇒ 同一格会出现两条，加载器会报"重复"）。


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


# ==================== 格子数事前估算（纯函数，不建盘）====================
#
# 【纯函数纪律】`estimate_cells` / `check_cell_budget` 一律 static、只做整数/字符串计算，
# **绝不**调用 `grid()` / `to_adjacency_grid()` / `setup_from_topo()`——那些会真的把盘建出来，
# 正是本层要避免的成本。未知 kind 退回方阵估值（宁可知情地保守，也不静默返回 0）。

## 估算给定结构会产出多少格（= 盘上可放雷的格子数）。
## `shape_kind == ""` 用 `rows*cols`；形状族按 `shape_params` 的几何族公式估算
##（与 `ShapeGenerator` 的 `*_cells_geo` 同口径，测试逐族对照真实格数防漂移）。
static func estimate_cells(shape_kind: String, shape_params: Dictionary, rows: int, cols: int) -> int:
	match shape_kind:
		"":
			return maxi(rows, 0) * maxi(cols, 0)
		"holed_grid":
			var r := int(shape_params.get("rows", rows))
			var c := int(shape_params.get("cols", cols))
			var holes_v: Variant = shape_params.get("holes", [])
			var holes: Array = holes_v if holes_v is Array else []
			return maxi(r * c - holes.size(), 0)
		"hex":
			# 与 build_hex 同一裁剪判据：abs(r + c - (size-1)) <= floor((size-1)/2)
			var size := int(shape_params.get("size", 0))
			if size <= 0:
				return 0
			var half := floori((size - 1) / 2.0)
			var n := 0
			for rr in size:
				for cc in size:
					if absi(rr + cc - (size - 1)) <= half:
						n += 1
			return n
		"t488":
			# size×size 个八边形 + (size-1)×(size-1) 个小方块
			var ts := int(shape_params.get("size", 0))
			if ts <= 0:
				return 0
			return ts * ts + maxi(ts - 1, 0) * maxi(ts - 1, 0)
		"tri_grid":
			# 每个菱形格切成上下两个三角形
			var c2 := int(shape_params.get("cols", cols))
			var r2 := int(shape_params.get("rows", rows))
			return maxi(2 * c2 * r2, 0)
		"iso_cubes":
			# 每个方块 = 3 个朝向面（洞按整个方块删）
			var c3 := int(shape_params.get("cols", cols))
			var r3 := int(shape_params.get("rows", rows))
			var h3_v: Variant = shape_params.get("holes", [])
			var h3: Array = h3_v if h3_v is Array else []
			return maxi((c3 * r3 - h3.size()) * 3, 0)
		"ring":
			var sectors_v: Variant = shape_params.get("sectors", [])
			var sectors: Array = sectors_v if sectors_v is Array else []
			var n3 := 0
			for s in sectors:
				n3 += int(s)
			return n3
		"circle":
			# (j) 圆：与 build_circle 同口径（内接正 precision 边形栅格化）。
			# 复用 ShapeGenerator 的**纯几何原语**（顶点 / 栅格化 / 点在多边形内），不建 AdjacencyGrid、
			# 不写任何状态 ⇒ 与 `build_circle(...)["positions"].size()` 天生逐格一致（测试逐族对拍）。
			var c_rad := int(shape_params.get("radius", 0))
			var c_prec := int(shape_params.get("precision", 24))
			if c_rad <= 0 or c_prec < 3:          # 与 build_circle 的拒绝条件一致 ⇒ 返回 0（无格）
				return 0
			var c_center := Vector2(float(c_rad), float(c_rad))
			return ShapeGenerator._rasterize_polygon(
				ShapeGenerator._regular_polygon_pts(c_center, float(c_rad), c_prec, -90.0)).size()
		"star":
			# (k) 星形：与 build_star 同口径（2*points 顶点、外/内半径交替、起始 -90°）。
			var s_pts := int(shape_params.get("points", 0))
			var s_outer := int(shape_params.get("outer_radius", 0))
			var s_ratio := float(shape_params.get("inner_ratio", 0.5))
			if s_pts < 3 or s_outer <= 0 or not is_finite(s_ratio) or s_ratio <= 0.0 or s_ratio >= 1.0:
				return 0
			var s_center := Vector2(float(s_outer), float(s_outer))
			return ShapeGenerator._rasterize_polygon(
				ShapeGenerator._star_polygon_pts(s_center, float(s_outer), s_ratio, s_pts)).size()
		"sector":
			# (l) 扇形：与 build_sector 同口径（精确极坐标判据 + 顶点集扫描窗，非多边形栅格化）。
			var f_rad := int(shape_params.get("radius", 0))
			var f_a0 := float(shape_params.get("start_deg", 0.0))
			var f_a1 := float(shape_params.get("end_deg", 90.0))
			if f_rad <= 0 or not is_finite(f_a0) or not is_finite(f_a1) or f_a0 < 0.0 or f_a1 > 360.0 or f_a0 >= f_a1:
				return 0
			var f_center := Vector2(float(f_rad), float(f_rad))
			var f_box: Rect2i = ShapeGenerator._verts_bbox(
				ShapeGenerator._sector_scan_verts(f_center, float(f_rad), f_a0, f_a1), 1)
			var f_n := 0
			for f_y in range(f_box.position.y, f_box.end.y):
				for f_x in range(f_box.position.x, f_box.end.x):
					if ShapeGenerator._sector_contains(f_center, float(f_rad), f_a0, f_a1,
							Vector2(float(f_x), float(f_y))):
						f_n += 1
			return f_n
		"ngon":
			# (m) 正 N 边形：与 build_ngon 同口径（内接正 sides 边形栅格化，起始 -90°）。
			# 与 circle 同一套纯几何原语 ⇒ 不建盘、不写状态，与 build_ngon 的 positions 逐格一致（测试对拍）。
			# tier 按 `to_adjacency_grid("ngon")` 的口径读（该入口**会**把 tier 传给 build_ngon）。
			var g_sides := int(shape_params.get("sides", 0))
			var g_rad := int(shape_params.get("radius", 0))
			var g_tier := str(shape_params.get("tier", ShapeGenerator.RASTER_DEFAULT))
			if g_sides < 3 or g_rad <= 0 or not ShapeGenerator.RASTER_TIERS.has(g_tier):
				return 0                     # 与 build_ngon 的拒绝条件一致 ⇒ 0 格（调用方的形状闸门会拦住）
			var g_center := Vector2(float(g_rad), float(g_rad))
			return ShapeGenerator._rasterize_polygon(
				ShapeGenerator._regular_polygon_pts(g_center, float(g_rad), g_sides, -90.0), g_tier).size()
		"annulus":
			# (n) 环形 annulus：与 build_annulus 同口径 —— 外环 + **反向**内环交给（奇偶判据的）栅格化。
			# ⚠ 与上面的 "ring"（同心环盘 build_ring）**同名不同义**，参数名也不同（这里是 outer/inner_radius）。
			var a_out := int(shape_params.get("outer_radius", 0))
			var a_in := int(shape_params.get("inner_radius", 0))
			var a_prec := int(shape_params.get("precision", 24))
			var a_tier := str(shape_params.get("tier", ShapeGenerator.RASTER_DEFAULT))
			if a_out <= 0 or a_in < 1 or a_in >= a_out or a_prec < 3:
				return 0                     # 与 build_annulus 的拒绝条件一致 ⇒ 0 格
			if not ShapeGenerator.RASTER_TIERS.has(a_tier):
				return 0                     # tier 非法同样建不出盘（build_annulus 会拒绝）
			var a_center := Vector2(float(a_out), float(a_out))
			var a_poly := ShapeGenerator._regular_polygon_pts(a_center, float(a_out), a_prec, -90.0)
			var a_hole := ShapeGenerator._regular_polygon_pts(a_center, float(a_in), a_prec, -90.0)
			for i in range(a_hole.size() - 1, -1, -1):
				a_poly.append(a_hole[i])     # 内环反向 = 规范"甜甜圈"环序（与 build_annulus 逐字同法）
			return ShapeGenerator._rasterize_polygon(a_poly, a_tier).size()
		"trihex":
			# 精确计数复用几何族（只产多边形，不建 AdjacencyGrid）
			return ShapeGenerator.trihex_cells_geo(
				int(shape_params.get("cols", cols)), int(shape_params.get("rows", rows))).size()
		"t31212":
			return ShapeGenerator.t31212_cells_geo(
				int(shape_params.get("cols", cols)), int(shape_params.get("rows", rows))).size()
		"mask":
			# 数"有格"字符。注意 t488 风格会额外补小方块 ⇒ 该风格下这是**下界**（宁可少算不误报 block）。
			var mask_v: Variant = shape_params.get("mask", [])
			var mask: Array = mask_v if mask_v is Array else []
			var n4 := 0
			for row in mask:
				var s := str(row)
				for i in s.length():
					if ShapeGenerator.MASK_FILLED.contains(s[i]):
						n4 += 1
			return n4
		"voronoi":
			# (p) Voronoi 不规则镶嵌：与 build_voronoi 同口径——复用同一批纯几何原语（确定性撒种 +
			# 多源波前进归属 + 单体素轮廓），**不建 AdjacencyGrid、不写任何状态**。
			# 种子来源二选一：显式 seeds（UI 拖动）优先，否则 sites/seed/jitter 确定性生成。
			var v_cols := int(shape_params.get("cols", cols))
			var v_rows := int(shape_params.get("rows", rows))
			if v_cols <= 0 or v_rows <= 0:
				return 0                     # 与 build_voronoi 的拒绝条件一致 ⇒ 0 格
			return ShapeGenerator.voronoi_cells_geo(v_cols, v_rows,
					ShapeGenerator.voronoi_seeds_of_params(v_cols, v_rows, shape_params)).size()
		_:
			return maxi(rows, 0) * maxi(cols, 0)


## 预算判定。返回 `{ok, level: "ok"|"warn"|"block", reason, hints}`。
##   · `ok == false` 只在 `level == "block"` 时出现 ⇒ 调用方据此**不执行**操作；
##   · `warn` 时 `ok == true` ⇒ 照常执行，但应把 `reason` 提示给用户；
##   · `hints` 恒为**三条出路**（降精度 / 合并格子 / 改参数），让用户不必自己想办法。
static func check_cell_budget(estimate: int, budget: int = DEFAULT_CELL_BUDGET) -> Dictionary:
	var hints := cell_budget_hints()
	if estimate <= 0:
		return {"ok": true, "level": "ok", "reason": "", "hints": hints}
	if estimate > MAX_CELL_BUDGET:
		return {"ok": false, "level": "block",
			"reason": "预计 %d 格，超过最高上限 %d（盘太大，编辑器与加载器都扛不住）" % [estimate, MAX_CELL_BUDGET],
			"hints": hints}
	if estimate > budget:
		return {"ok": true, "level": "warn",
			"reason": "预计 %d 格，超过预算 %d（仍会执行；盘越大编辑与预览越慢）" % [estimate, budget],
			"hints": hints}
	return {"ok": true, "level": "ok", "reason": "", "hints": hints}


## 三条出路（`check_cell_budget` 的 `hints`，也是 UI 弹提示时逐条告诉用户的话）。
static func cell_budget_hints() -> Array:
	return [
		"降精度：把「行 / 列」或形状尺寸调小",
		"合并格子：把用不到的边角设成障碍（格数按盘上实际格计）",
		"改参数：减少邻域偏移，或换回方形盘（形状盘格数由参数决定）",
	]


## 当前结构的事前估算（纯计算，不建盘）。
func estimate_cells_now() -> int:
	return estimate_cells(shape_kind, shape_params, rows, cols)


## 当前结构的预算判定；比 static 版多带一个 `estimate` 字段，方便 UI 直接取用。
func cell_budget_report(budget: int = DEFAULT_CELL_BUDGET) -> Dictionary:
	var rep := check_cell_budget(estimate_cells_now(), budget)
	rep["estimate"] = estimate_cells_now()
	return rep


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
	var raw := _build_topology_raw()
	if raw.is_empty() or obstacles.is_empty():
		return raw
	return _carve_holes(raw, obstacles)


## 未挖洞的拓扑（洞格**仍作为存在的格**保留）：与 `_build_topology()` 只差"最后不 `_carve_holes`"。
##
## 【为什么必须单独有这一条】腐蚀 / 膨胀要能"长进洞里"、也要能"从洞里长回来"。若拿**已挖洞**的盘
## 当判界（`grid().in_board()` 对洞格恒 false），"膨胀补回洞"这条路径物理上不可达 ⇒ 按钮点了没反应，
## 是个假功能。故 `core/shape_smooth.gd` 的判界一律走本函数的产物（见 `space_grid()`）。
func _build_topology_raw() -> Dictionary:
	if shape_kind != "":
		# 形状族：借 `ShapeGenerator` 的 9 族实现（六边形/三角/截角/环/轮廓…），不自己造
		var g: AdjacencyGrid = ShapeGenerator.to_adjacency_grid(shape_kind, shape_params)
		if g == null:
			return {}
		# ⚠ 必须归一到非负坐标：六边形等以中心为原点 ⇒ 负坐标会让 CP-SAT 索引越界、
		# 并让审计报"存在负坐标"（`AdjacencyGrid.normalized` 就是为这件事存在的）。
		return _topology_dict_of(AdjacencyGrid.normalized(g))
	if not foreign_topology.is_empty():
		# 外部盘型：原样返回（障碍只做"再挖一次洞"，幂等）。**绝不**按 dirs/wrap 重建。
		return foreign_topology
	var r := WrapTopology.build(rows, cols, dirs, include_self, wrap, not obstacles.is_empty())
	if not bool(r["ok"]):
		return {}
	return r["topology"]


## 棋盘对象（矩形盘 RectGrid / 其余 AdjacencyGrid），供预览与验证共用。
## 带缓存：`setup_from_topo` 在 64x64 环绕盘上实测 91.5 ms，不能每次预览都重建。
func grid() -> GridInterface:
	var sig := struct_signature()
	if sig == _grid_sig and _grid_cache != null:
		return _grid_cache
	_grid_cache = _grid_from_topo(topology())
	_grid_sig = sig
	return _grid_cache


## 未挖洞的「盘空间」（洞格存在）：给腐蚀 / 膨胀这类形态学当判界用
##（与 `grid()` 区别 = 不 `_carve_holes`；理由见 `_build_topology_raw()`）。带缓存，签名同 `grid()`。
func space_grid() -> GridInterface:
	var sig := struct_signature()
	if sig == _space_sig and _space_cache != null:
		return _space_cache
	_space_cache = _grid_from_topo(_build_topology_raw())
	_space_sig = sig
	return _space_cache


## 拓扑字典 → 网格对象（空拓扑 = 默认矩形盘 RectGrid）。`grid()` / `space_grid()` 共用，避免两处建盘口径日久漂移。
func _grid_from_topo(topo: Dictionary) -> GridInterface:
	if not topo.is_empty():
		var ag := AdjacencyGrid.new()
		ag.setup_from_topo(topo)
		return ag
	var rg := RectGrid.new()
	rg.setup(rows, cols)
	return rg


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

## 问题分级（W3）：❌error 阻止试玩/保存，⚠️warn 提醒但放行，💡info 纯提示（可忽略）。
const ISSUE_ERROR := "error"
const ISSUE_WARN := "warn"
const ISSUE_INFO := "info"

## 返回 {"ok", "errors", "warnings", "infos", "issues"}。
## 每条问题 = {code(类别 id), text(人话消息), pos(格子坐标, Vector2i(-1,-1)=与格无关), level(三级)}。
## 向后兼容：`errors` 仍是 error；`warnings` 仍是**非阻塞项**（warn ∪ info，老读取方所见不减少）；
## 新代码请用 `issues`（三级统一、含 level）或按 level 过滤。
func validate() -> Dictionary:
	var errors: Array = []
	var warnings: Array = []
	var infos: Array = []

	# 1) 尺寸 / 邻域（走 WrapTopology 同一套上限与退化判据，避免两处规则不一致）
	if rows < 1 or cols < 1:
		errors.append(_issue("size", "棋盘尺寸非法（%dx%d）" % [rows, cols], Vector2i(-1, -1), ISSUE_ERROR))
	elif rows * cols > MAX_CELLS:
		errors.append(_issue("size", "格数 %d 超过上限 %d" % [rows * cols, MAX_CELLS], Vector2i(-1, -1), ISSUE_ERROR))
	var built := WrapTopology.build(rows, cols, dirs, include_self, wrap, false)
	if not bool(built["ok"]):
		errors.append(_issue("neighborhood", str(built["reason"]), Vector2i(-1, -1), ISSUE_ERROR))
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
	# 指出"哪一格"度数最高：UI 才能把这一格高亮出来（否则用户只知道有事情、不知道在哪）。
	var worst_cell := Vector2i(-1, -1)
	if deg > neighbor_cap_warn:
		worst_cell = _max_degree_cell()
	if deg > neighbor_cap_block:
		errors.append(_issue("neighbor_huge",
			"单格邻接 %d 格（上限 %d）—— 这一格的数字没法读、求解器也算不动：请减少邻域偏移" % [deg, neighbor_cap_block],
			worst_cell, ISSUE_ERROR))
	elif deg > neighbor_cap_warn:
		warnings.append(_issue("neighbor_many",
			"单格邻接 %d 格（超过 %d 就该警惕）—— 那格的数字会很难读" % [deg, neighbor_cap_warn], worst_cell))

	# 2) 雷位
	var mseen := {}
	for m in mines:
		if m.x < 0 or m.y < 0 or m.x >= cols or m.y >= rows:
			errors.append(_issue("mine_oob", "雷位越界 (%d,%d)" % [m.x, m.y], m, ISSUE_ERROR))
			continue
		if mseen.has(m):
			errors.append(_issue("mine_dup", "雷位重复 (%d,%d)" % [m.x, m.y], m, ISSUE_ERROR))
		mseen[m] = true
		if obstacles.has(m):
			errors.append(_issue("mine_on_obstacle", "雷位落在障碍格上 (%d,%d)" % [m.x, m.y], m, ISSUE_ERROR))
	if declared_total_mines >= 0 and declared_total_mines != mines.size():
		errors.append(_issue("declared_mismatch",
			"声明的总雷数 %d 与实际雷位 %d 颗不一致（导出按声明值写入 ⇒ 求解必然矛盾）" % [declared_total_mines, mines.size()],
			Vector2i(-1, -1), ISSUE_ERROR))
	if mines.is_empty():
		errors.append(_issue("no_mines", "还没有地雷：至少放 1 颗才能试玩/验证", Vector2i(-1, -1), ISSUE_ERROR))
	elif cell_count() > 0 and mines.size() >= cell_count():
		errors.append(_issue("mines_ge_cells", "雷数 %d ≥ 可用格数 %d" % [mines.size(), cell_count()], Vector2i(-1, -1), ISSUE_ERROR))
	if not mines.is_empty() and density() > 0.5:
		infos.append(_issue("density_high", "雷密度 %.0f%% 偏高（>50%%）：这类关卡通常不可推" % (density() * 100.0), Vector2i(-1, -1), ISSUE_INFO))

	# 3) 障碍与初始翻开
	var oseen := {}
	for o in obstacles:
		if o.x < 0 or o.y < 0 or o.x >= cols or o.y >= rows:
			errors.append(_issue("obstacle_oob", "障碍越界 (%d,%d)" % [o.x, o.y], o))
			continue
		if oseen.has(o):
			errors.append(_issue("obstacle_dup", "障碍重复 (%d,%d)" % [o.x, o.y], o, ISSUE_ERROR))
		oseen[o] = true
		if revealed.has(o):
			errors.append(_issue("obstacle_revealed", "障碍格不能同时是初始翻开格 (%d,%d)" % [o.x, o.y], o, ISSUE_ERROR))
	for p in revealed:
		var pos: Vector2i = p
		if pos.x < 0 or pos.y < 0 or pos.x >= cols or pos.y >= rows:
			errors.append(_issue("revealed_oob", "初始翻开格越界 (%d,%d)" % [pos.x, pos.y], pos, ISSUE_ERROR))
		elif mseen.has(pos):
			# 注意：GDScript 字符串里不能用嵌套的双引号，这里用「」代替
			errors.append(_issue("revealed_mine", "初始翻开格是雷 (%d,%d)（「雷格 ? 后门」拦截）" % [pos.x, pos.y], pos, ISSUE_ERROR))

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
				errors.append(_issue("mine_off_board", "雷位不在盘上（形状盘/外部拓扑盘上的空位）：(%d,%d)" % [m.x, m.y], m, ISSUE_ERROR))

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
					_audit_errors.append(_issue("topology", "邻接表体检未通过：%s" % "；".join(audit["problems"]),
						Vector2i(-1, -1), ISSUE_ERROR))
				# 孤立格：有邻域定义却一个邻居都没有（偏移写错、或被障碍隔开）——
				# audit 只给整表级结论，这里逐格给坐标，UI 才能高亮到点上。
				# 纯提示（💡）：格子的数字/推理不受影响，只是作者该知道。
				# **只对编辑器自己生成的方阵邻域告警**：外部拓扑（六边形/三角/放射环…）里
				# 单个格没有邻居完全可能是作者的设计，对别人的盘指手画脚只会刷屏。
				if ag.cell_count() > 1 and foreign_topology.is_empty() and shape_kind == "":
					for p in ag.all_positions():
						if ag.get_neighbors(p).is_empty():
							_audit_warnings.append(_issue("isolated_cell",
								"该格没有任何邻居（排版偏移写错，或被障碍隔开）", p, ISSUE_INFO))
			for e in _audit_errors:
				errors.append(e)
			# 审计告警当前只有 💡info 级；仍会经「warnings = warn ∪ info」兼容桶出现在 warnings 里。
			for w2 in _audit_warnings:
				infos.append(w2)

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
				errors.append(_issue("spec", "规则没通过检查：%s" % str(e), Vector2i(-1, -1), ISSUE_ERROR))
		for w in sv.get("warnings", []):
			infos.append(_issue("spec_warn", "规则提醒：%s" % str(w), Vector2i(-1, -1), ISSUE_INFO))
	var rule := rule_object()
	if rule == null:
		errors.append(_issue("rule_missing", "规则未注册/未解析：%s" % rule_id_effective(), Vector2i(-1, -1), ISSUE_ERROR))
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
				+ "请把棋盘改回方形；或改用「所有相邻格」那条配方；或让 AI 按「相邻格」重写这条规则。",
				Vector2i(-1, -1), ISSUE_ERROR))

	# 4.5) 反向几何坑：**「按相邻格定义」的规则 × 普通方盘 = 数字全 0**（而且平台不报错）
	# `SpecRulePlugin.compute_clue` 对 `refs="topo"` 直接返回 empty_value（core/spec_rule_plugin.gd:151-156），
	# 而普通方阵盘（RectGrid）走的正是 compute_clue ⇒ 每格数字都变成 0。
	# 零代码路径（让 AI 按"相邻格"写规则）最容易踩它：小白看到满盘 0 只会以为编辑器坏了 ⇒
	# 必须显式说明原因并给出**可执行的出路**（打开环绕 / 换形状盘 / 改成固定方向写法）。
	if not rule_spec.is_empty() and topology().is_empty():
		var clue_v: Variant = rule_spec.get("clue", {})
		if clue_v is Dictionary and str((clue_v as Dictionary).get("refs", "")) == "topo":
			infos.append(_issue("topo_needs_table",
				"这条规则按「相邻格」定义（refs=\"topo\"），而当前是**普通方盘**（没有邻接表）：数字会全显示 0。"
				+ "请勾选「环绕边界」或换六边形盘；或让 AI 改成「固定方向 + geometry=\"rect_only\"」的写法。",
				Vector2i(-1, -1), ISSUE_INFO))

	# 5) 结构校验（复用仓库既有校验器：保证"能保存的必定能加载"）
	if mines.size() > 0 and errors.is_empty():
		var ls := LevelValidator.validate_structure(to_level_json())
		if not bool(ls["ok"]):
			errors.append(_issue("structure", str(ls["reason"]), Vector2i(-1, -1), ISSUE_ERROR))

	# 6) 不编辑但会原样保留的字段：如实提醒（避免作者以为编辑器"看懂"了它们）。
	# 这些都不影响"能不能玩"，属纯提示（💡info）。
	if shape_kind != "":
		infos.append(_issue("shape_active",
			"当前是**形状盘**（%s）：棋盘由 ShapeGenerator 生成，「邻域偏移 / 环绕边界 / 含自身」不适用；"
			% shape_kind + "编辑器只编辑雷位、障碍与规则（盘型随形状参数变化）", Vector2i(-1, -1), ISSUE_INFO))
	if not foreign_topology.is_empty():
		infos.append(_issue("foreign_topology",
			"该盘使用**外部拓扑**（六边形/三角/自定义轮廓等，非本编辑器的方阵邻域）："
			+ "「邻域偏移 / 环绕边界 / 含自身」控件对它不适用，编辑器只编辑雷位、障碍与规则；盘型原样保留",
			Vector2i(-1, -1), ISSUE_INFO))
	if not _revealed_extras.is_empty():
		infos.append(_issue("revealed_extras", "该关卡含遮蔽区间等附加 revealed 条目：编辑器不编辑，导出时原样保留",
			Vector2i(-1, -1), ISSUE_INFO))
	if passthrough.has("variant") or passthrough.has("clue_def"):
		infos.append(_issue("foreign_variant", "该关卡用内置线索变体（variant/clue_def）定义线索：预览按规则口径计算，可能与其语义不同",
			Vector2i(-1, -1), ISSUE_INFO))
	# 6b) `custom.schema_id` **一键一义**：编辑器只要带了规则 spec，保存时就必署自己的 `SCHEMA_ID`
	#（文档口径，见 `_level_dict`）⇒ 外来的 Mod schema 引用会被覆盖且不可恢复。
	# 这种覆盖**必须可见**（不许静默）：它是"键还在、指向没了"的典型，配套的 Mod custom 负载
	# 会一起变成无人校验的野数据。非阻塞（warn）：用户可能就是要用编辑器规则。
	if not rule_spec.is_empty() and custom_passthrough.has("schema_id"):
		var foreign_sid := str(custom_passthrough.get("schema_id", ""))
		if foreign_sid != "" and foreign_sid != SCHEMA_ID:
			warnings.append(_issue("schema_id_overwrite",
				"这关的 `custom.schema_id` 是外来的「%s」（Mod 自定义 schema 的选表键）；" % foreign_sid
				+ "而本关带编辑器规则 spec ⇒ 本次保存会把它署成本编辑器的「%s」，**原值不可恢复**。" % SCHEMA_ID
				+ "若那个 schema 引用还要用，请先备份该关卡。",
				Vector2i(-1, -1)))

	# 兼容桶：`warnings` 保持「非阻塞项」（warn ∪ info）——老读取方所见不减少；
	# 新代码按 `level` 或 `infos` 区分 💡。`issues` 是三级统一列表（error→warn→info）。
	var non_blocking: Array = []
	non_blocking.append_array(warnings)
	non_blocking.append_array(infos)
	var all_issues: Array = []
	all_issues.append_array(errors)
	all_issues.append_array(non_blocking)
	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"warnings": non_blocking,
		"infos": infos,
		"issues": all_issues,
	}


## 三级问题里出现的格坐标（UI 高亮用；去重、剔除 (-1,-1)）。info 也收：
## "该格没有任何邻居"这类提示同样希望用户能跳到点上。
func highlight_cells(report: Dictionary = {}) -> Array[Vector2i]:
	var r := report if not report.is_empty() else validate()
	var out: Array[Vector2i] = []
	for bucket in ["errors", "warnings", "infos"]:
		for it in r.get(bucket, []):
			var pos: Vector2i = (it as Dictionary)["pos"]
			if pos.x >= 0 and pos.y >= 0 and not out.has(pos):
				out.append(pos)
	return out


## 度数最高的格（邻接规模门禁要报"是哪一格"，UI 才高亮得到）。
## 非环绕盘上角格度数天然更低，取"最大度数"的那一格作为代表；取不到返回 (-1,-1)。
func _max_degree_cell() -> Vector2i:
	var g := grid()
	if g == null:
		return Vector2i(-1, -1)
	var extra := 1 if include_self else 0
	var out := Vector2i(-1, -1)
	var best := -1
	for p in g.all_positions():
		var d: int = g.get_neighbors(p).size() + extra
		if d > best:
			best = d
			out = p
	return out


static func _issue(code: String, text: String, pos := Vector2i(-1, -1), level := ISSUE_WARN) -> Dictionary:
	return {"code": code, "text": text, "pos": pos, "level": level}


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
	# `size` 同属**部分识别**容器：未知子键（如 Mod 的额外维度）原样带回，再写本模型认识的 rows/cols。
	# 老文档（size 只有 rows/cols）输出与改动前逐键一致（顺序也一致）。
	var size_out: Dictionary = _size_extras.duplicate(true)
	size_out["rows"] = rows
	size_out["cols"] = cols
	out["size"] = size_out
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

	# 骨牌划分（关卡内容）：写**生成器/Board 认的 `[[{c,r},…]]` 形态**（经坐标桥 x→c、y→r）。
	# 空 ⇒ 不写键：不含骨牌的老文档，JSON 输出与改动前逐键一致。
	if dominoes.count() > 0:
		out["dominoes"] = dominoes_to_level(dominoes)

	var rid := rule_id_effective()
	if not rule_spec.is_empty():
		out["rule_level"] = true
		out["clue_rule"] = rid
	elif clue_rule_id != "":
		out["rule_level"] = true
		out["clue_rule"] = clue_rule_id
	if not global_rule_ids.is_empty():
		out["global_rules"] = Array(global_rule_ids)

	# `custom` 是**部分识别**的容器：以"载入时留存的未知子键"为底，再写本模型认识的键。
	# 若从 `{}` 重建，Mod 自定义字段与将来新增的字段就会在"打开→另存"一次后消失。
	var custom: Dictionary = custom_passthrough.duplicate(true)
	if not rule_spec.is_empty():
		# 编辑器自带 spec ⇒ 按文档口径署自己的 schema 标记（覆盖外来值是有意的：spec 与本标记同生共死）。
		custom["schema_id"] = SCHEMA_ID
		custom["spec"] = rule_spec.duplicate(true)
	if not warp_points.is_empty():
		custom["warp_points"] = _cells_json(warp_points)
	if not regions.is_empty():
		custom["regions"] = regions.duplicate(true)
	# 复合格（关卡内容）：`MegaCell.to_dict()` 原文进 custom（Board 不读它，故不占主字段）。
	if mega_cells.count() > 0:
		custom["mega_cells"] = mega_cells.to_dict()
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
## ── W1：**撤销记"改动"而不是整盘快照**（清单·数据爆炸 D）────────────────────────
## 清单原文：连续微操作要合并成一步；**大棋盘撤销用"记录改动"而不是"整个棋盘快照"** ——
## 5000 格 × 200 张快照 ≈ 上百 MB。这里的口径：
##   · 每次改动前对**受影响的格**记一次"改动前的状态"（每格 3 个 int：x, y, code ≈12B）；
##   · 撤销 = 把这些格恢复成记录里的状态；重做 = 把撤销时记下的"当时状态"再恢复回去；
##   · 只有结构/大批量改动（改尺寸、换邻域、随机布雷…）才由调用方走 `snapshot()` 兜底。
const CELL_EMPTY := 0
const CELL_MINE := 1
const CELL_OBSTACLE := 2
const CELL_REVEALED := 3

var _diff: PackedInt32Array = PackedInt32Array()
var _diff_seen: Dictionary = {}


## 一格当前状态（雷↔障碍↔初始翻开三集合互斥 ⇒ 单值就能表达）。
func state_code(p: Vector2i) -> int:
	if mines.has(p):
		return CELL_MINE
	if obstacles.has(p):
		return CELL_OBSTACLE
	if revealed.has(p):
		return CELL_REVEALED
	return CELL_EMPTY


## 把一格设成指定状态（与 `EditorCanvas._apply_kind` 同一套互斥语义：先清三集合再写一个）。
func set_state(p: Vector2i, code: int) -> void:
	mines.erase(p)
	obstacles.erase(p)
	revealed.erase(p)
	match code:
		CELL_MINE:
			mines.append(p)
		CELL_OBSTACLE:
			obstacles.append(p)
		CELL_REVEALED:
			revealed[p] = null


## 记一格"改动前的状态"（同一格只记第一次 —— 那才是撤销点；重笔刷不该把第一次覆盖掉）。
func note_cell(p: Vector2i) -> void:
	if _diff_seen.has(p):
		return
	_diff_seen[p] = true
	_diff.append(p.x)
	_diff.append(p.y)
	_diff.append(state_code(p))


func has_diff() -> bool:
	return not _diff.is_empty()


## 取出当前 diff 并清空暂存（空数组 = 这步没有格子级改动 ⇒ 调用方退回快照兜底）。
func take_diff() -> PackedInt32Array:
	var out := _diff
	_diff = PackedInt32Array()
	_diff_seen.clear()
	return out


## 应用一条 diff（把每条 `[x,y,code]` 恢复成 code），并**返回反向 diff**（供重做）。
func apply_diff(cells: PackedInt32Array) -> PackedInt32Array:
	var inverse := PackedInt32Array()
	var i := 0
	while i + 2 < cells.size():
		var p := Vector2i(cells[i], cells[i + 1])
		var code := cells[i + 2]
		inverse.append(p.x)
		inverse.append(p.y)
		inverse.append(state_code(p))
		set_state(p, code)
		i += 3
	return inverse


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
		# ⚠ 形状参数也必须**显式**存（2026-10-03 修）：`load_from()` 会把 `shape_kind/shape_params`
		# 清零（见本文件 :866-867）⇒ 快照里不带它们，"换形状后按撤销"会悄悄退回方阵，
		# 用户手工改过的格子与形状定义一起丢。清单也明确要求"形状参数随时改、改完一键重新生成"，
		# 那么撤销就必须能回到**原形状**，而不是回到一个看似正常的方阵。
		"shape": {"kind": shape_kind, "params": shape_params.duplicate(true)},
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
	var sh: Variant = snap.get("shape", {})
	if sh is Dictionary:
		shape_kind = str((sh as Dictionary).get("kind", ""))
		var pr: Variant = (sh as Dictionary).get("params", {})
		shape_params = (pr as Dictionary).duplicate(true) if pr is Dictionary else {}
	return true


func load_from(level: Dictionary) -> Dictionary:
	var sz: Variant = level.get("size", {})
	if not (sz is Dictionary):
		return {"ok": false, "reason": "关卡缺少 size"}
	var szd: Dictionary = sz
	rows = int(szd.get("rows", 0))
	cols = int(szd.get("cols", 0))
	if rows < 1 or cols < 1:
		return {"ok": false, "reason": "关卡尺寸非法（%dx%d）" % [rows, cols]}
	# `size` 的部分识别：只认 rows/cols，其余子键原样带回（与 `custom` 同一类缺口）。
	_size_extras = szd.duplicate(true)
	for k in SIZE_KNOWN_KEYS:
		_size_extras.erase(k)
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
	custom_passthrough = {}
	var custom: Variant = level.get("custom", {})
	if custom is Dictionary:
		var cust: Dictionary = custom
		warp_points = _parse_cells(cust.get("warp_points", []))
		var rg: Variant = cust.get("regions", [])
		regions = (rg as Array).duplicate(true) if rg is Array else []
		# 其余子键（Mod 自定义字段 / 将来新增字段）**原样留存**，导出时写回。
		# 只剔除本模型认识的键，绝不"从 `{}` 重建"（重建 = 静默丢键）。
		custom_passthrough = cust.duplicate(true)
		for k in CUSTOM_KNOWN_KEYS:
			custom_passthrough.erase(k)

	# 复合格 / 骨牌划分：**关卡内容**，与雷位同桶（从 JSON 读入），
	# **绝不**放进上面那段"清空会话编辑选择"（wrap/dirs/障碍/shape_kind…）——依据：
	#   · 那段只清"由参数重新推导的会话选择"（见该段注释：形状族"不是关卡字段"）；
	#   · 这两个是**真按字段存进关卡 JSON** 的内容（`MegaCell`/`DominoModel` 集成点注释也如此约定），
	#     清掉就等于"打开关卡再保存丢内容"。
	# 老 JSON 没有这两个键 ⇒ 按"无"处理（空集合），不报错。
	dominoes = dominoes_from_level(level.get("dominoes", []))
	mega_cells = MegaCell.new()
	if custom is Dictionary:
		var mc: Variant = (custom as Dictionary).get("mega_cells", {})
		if mc is Dictionary and not (mc as Dictionary).is_empty():
			mega_cells = MegaCell.from_dict(mc)

	passthrough = {}
	var known := ["name", "size", "total_mines", "mines", "revealed", "rule_level", "clue_rule",
		"global_rules", "topology", "custom", "dominoes"]
	for k in level:
		if not known.has(k):
			passthrough[k] = level[k]
	return {"ok": true, "reason": ""}


func _cells_json(cells: Array[Vector2i]) -> Array:
	var out: Array = []
	for p in cells:
		out.append({"r": p.y, "c": p.x})
	return out


## ⚠ 只保留 c/r（容错 x/y）：条目级附加键（note/flag/value…）**会丢**——本仓无产出方写它们，
# 且本函数在解析热路径上，故本轮接受（详见文件顶部「已知且本轮接受的丢键」）。
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


# ==================== 坐标桥：dominoes（c/r ↔ x/y）====================
#
# 【为什么必须有它】本仓两套口径并存，**接线处最容易接错**（前一位子 Agent 实测）：
#   · 生成器落盘 / `Board._parse_dominoes`（core/board.gd:606-620）只认键 **`c` / `r`**
#     （`Vector2i(int(p["c"]), int(p["r"]))`）；
#   · `DominoModel` 的内部 cell 是 **`[x, y]`**（`Vector2i(c, r)`，见 domino_model.gd 集成点 2）。
# 换算**只有一条**：`c = x`、`r = y`（与 `to_level_json` 的 `{r, c}`、`Board` 的 `Vector2i(c, r)` 同源）。
# 换算**只发生在这两个静态桥函数里**——模型与关卡 JSON 各自保持口径，谁都不迁就谁；
# 因此"生成器落盘形态"进模型再写回，形态不变（不出现 `{x,y}` 与 `{c,r}` 两套键混写）。

## 关卡 JSON → `DominoModel`：吃 `[[{c,r},{c,r}], …]`（生成器/Board 形态）。
## 非 2 格 / 非法条目按 `Board._parse_dominoes` 同口径跳过；id 由桥按 1..n 顺序分配
##（关卡形态本就不带 id，写回时也不写 id ⇒ 形态不变）。
static func dominoes_from_level(raw: Variant) -> DominoModel:
	var model := DominoModel.new()
	if not (raw is Array):
		return model
	var items: Array = []
	var next_id := 1
	for entry: Variant in raw:
		var cells := _level_pair_to_xy(entry)
		if cells.size() != 2:
			continue
		items.append({"id": next_id, "cells": cells})
		next_id += 1
	return DominoModel.from_dict({"version": DominoModel.VERSION, "next_id": next_id, "dominoes": items})


## `DominoModel` → 关卡 JSON：写回 `[[{c,r},{c,r}], …]`（**形态与读入一致**，Board 直接可吃）。
static func dominoes_to_level(model: DominoModel) -> Array:
	var out: Array = []
	if model == null:
		return out
	for rec: Dictionary in model.dominoes():
		var entry: Array = []
		for p: Vector2i in (rec["cells"] as Array):
			entry.append({"c": p.x, "r": p.y})   # x→c、y→r
		out.append(entry)
	return out


## 单张骨牌的 JSON → 模型 cell 列表 `[[x,y],…]`（c→x、r→y）。
## 宽容已写成 `{x,y}` 的输入（旧实验数据），但**优先 `c/r`**（生成器/Board 的口径）。
static func _level_pair_to_xy(entry: Variant) -> Array:
	var out: Array = []
	if not (entry is Array):
		return out
	for p: Variant in entry:
		if not (p is Dictionary):
			continue
		var d: Dictionary = p
		if d.has("c") and d.has("r"):
			out.append([int(d["c"]), int(d["r"])])
		elif d.has("x") and d.has("y"):
			out.append([int(d["x"]), int(d["y"])])
	return out
