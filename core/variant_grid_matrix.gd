# variant_grid_matrix.gd —— 变体 × 网格族 兼容矩阵（W9「勾选即时禁用」门禁的唯一事实源）
#
# 【为什么需要】
#   `core/variant_registry.gd` 只回答「有哪些变体」与「变体 × 变体是否禁止」（`global_pair_compat`
#   的 forbid/warn 表）；它完全不知道「棋盘是六边形 / 三角形 / 环盘」。而 15 个变体的语义几乎
#   全部长在**矩形行列**上（行 / 高度 / 2×2 窗口 / 染色 / 中轴 / 方向环序）——异形盘上
#   「勾了变体、生成期却回退 / 丢弃」是本项目最贵的坑之一。生成期的异形门控见
#   core/puzzle_generator.gd:463-498：**线索型与全局约束型同一判据**（`supports_topology()`），
#   线索型回退 classic、全局约束型丢弃（等价于未勾选），两者都大声告警并同步落盘名单。
#   本文件把「变体 × 网格族」钉成一张**数据表 + 三态查询**，门禁直接消费它，不必各自猜。
#
# 【网格族来自代码，不凭想象】
#   12 族 = `core/shape_generator.gd` 的 `to_adjacency_grid(kind, ...)` 全部 kind
#   （holed_grid / hex / t488 / iso_cubes / tri_grid / trihex / t31212 / ring / mask，
#   加 (j)~(l) 参数化轮廓族 circle / star / sector），
#   与 HANDOFF 的形状族表、`ui/variant_catalog.gd:416-424` 的形状卡片同源。
#   其中 circle / star / sector 与 holed_grid 同为「整数格上的 Moore 8 邻子集」——坐标轴仍是
#   包围盒行列，只是盘内格不铺满；故全局约束型在这三族上的三态与 holed_grid 同判（见下）。
#   另加两个基线/结构族（都是仓库里真实走得到的盘）：
#     · `rect`      —— 默认矩形盘：关卡无 `topology` ⇒ RectGrid（core/board.gd:164-171 else 分支）；
#     · `rect_wrap` —— 环绕矩形盘：WrapTopology.build 产出邻接表（core/wrap_topology.gd:51-108）
#                      ⇒ 关卡带 topology ⇒ 走 AdjacencyGrid ⇒ 同一道异形门控。
#   Voronoi / 布尔复合格**在仓库里不存在**（docs/plans/2026-10-03-editor-feature-program.md:26
#   列为「必须先建子系统」）⇒ 查询落到未知族兜底（DISABLED + 原因），不臆造语义。
#
# 【变体的几何声明来自代码，不凭想象】
#   适用性由变体自己的 `RulePlugin.geometry_kind()` 声明（core/rule_plugin.gd:47-58）决定：
#   GEO_ADJ_GENERIC(0) = 任意拓扑可用；GEO_RECT_ONLY(1) = 依赖矩形几何（基类默认，core/rule_plugin.gd:52-53）。
#   实现处的 file:line 逐项写在各条目的 `evidence` 里。15 个内置变体里**只有 classic 声明 GENERIC**。
#
# 【三态判据（保守：证明不了语义完整就降级/禁用）】
#   OK       —— 语义完整：变体声明 GEO_ADJ_GENERIC，且线索/约束只用拓扑邻域。
#   DEGRADED —— 该族上**仍存在一个可解释的较弱语义**（坐标轴与几何轴一致，只是覆盖不全），
#               并附**非空退化清单**（受影响语义）。
#               【2026-10-03 门控补齐后：本表当前**无 DEGRADED 格**】——此前 DEGRADED 只有一类
#               实例：全局约束型在 4 个缺格族（holed_grid / circle / star / sector，即
#               BBOX_SUBSET_KINDS）与 rect_wrap 上「仍会被原样构建」，故「按包围盒强算」
#               确有其事、可解释为较弱语义。现在生成期对全局约束型也做了异形门控
#               （core/puzzle_generator.gd:473-498），这些组合**会被拦住**（约束被丢弃）⇒
#               弱语义不再存在 ⇒ 一律 DISABLED。保留 DEGRADED 态 = 三态契约：
#               将来某变体在某族上确有可解释的弱语义时再启用（必须带非空清单，test 断言充要）。
#   DISABLED —— 二者之一：①变体不生效——线索型在邻接表盘上被生成期回退经典并告警
#               （core/puzzle_generator.gd:463-472）；全局约束型被生成期**丢弃**并告警
#               （core/puzzle_generator.gd:473-498）；
#               ②「行 / 列 / 2×2 窗口 / 染色 / 中轴」在该族上没有几何对应——按包围盒坐标
#               强算得到的是**另一个**约束（core/rule_builder.gd:56-59：盘外格按常量 0 参与）。
#               一律附用户可读原因，宁禁不放。
#
# 【矩形盘】`rect` 上 15 个变体全部 OK —— 变体的定义域就是矩形盘（VariantRegistry 的定义表 +
# 各实现的矩形口径），这正是其余族要对照的基线。
class_name VariantGridMatrix
extends RefCounted

const OK := "OK"
const DEGRADED := "DEGRADED"
const DISABLED := "DISABLED"

# 网格族。前两个是结构基线，其余 12 个与 ShapeGenerator.to_adjacency_grid 的 kind 一一对应。
const RECT := "rect"
const RECT_WRAP := "rect_wrap"
const HOLED_GRID := "holed_grid"
const HEX := "hex"
const T488 := "t488"
const ISO_CUBES := "iso_cubes"
const TRI_GRID := "tri_grid"
const TRIHEX := "trihex"
const T31212 := "t31212"
const RING := "ring"
const CIRCLE := "circle"
const STAR := "star"
const SECTOR := "sector"
const MASK := "mask"

const ALL_KINDS: Array = [RECT, RECT_WRAP, HOLED_GRID, HEX, T488, ISO_CUBES,
		TRI_GRID, TRIHEX, T31212, RING, CIRCLE, STAR, SECTOR, MASK]

# 「整数格上 Moore 8 邻的子集」= 缺格族：坐标轴仍是包围盒行列，但盘内格不铺满。
# 用途有二（都是**族等价类**，不是三态判据本身）：
#   ① 原因文案：这些族上「行 / 列 / 2×2 窗口 / 中轴 / 染色」没有几何对应，理由与 holed_grid
#      同源（缺格使包围盒坐标轴与盘面几何轴不再重合）⇒ _missing_axis_clause() 按本表给同一句话；
#   ② 交叉校验：circle / star / sector 与 holed_grid 必须**逐格同判**（variant_ids × 本表），
#      由 test_variant_grid_matrix 断言，防四族在三态上漂移。
# 【2026-10-03 门控补齐后】线索型与全局约束型在本族与其余异形族**同判**（一律 DISABLED）：
# 生成期异形门控的判据是 rules 自己的 supports_topology()，与网格族无关。
const BBOX_SUBSET_KINDS: Array = [HOLED_GRID, CIRCLE, STAR, SECTOR]

# `mask` 是轮廓容器族：几何由 style 决定，取值 ⊆ ShapeGenerator.MASK_STYLES
#（core/shape_generator.gd:53-54）。本表按这 3 族取**最保守者**（由 test 与常量交叉校验）。
const MASK_STYLE_KINDS: Array = [HOLED_GRID, HEX, T488]


## 矩阵的全部网格族（顺序 = 上表顺序）。
static func grid_kinds() -> Array[String]:
	var out: Array[String] = []
	out.assign(ALL_KINDS)
	return out


static func is_known_grid_kind(grid_kind: String) -> bool:
	return ALL_KINDS.has(grid_kind)


## 矩阵里登记的全部变体 id（升序）。正常应与 `VariantRegistry.all_codes()` 集合相等
## （由 test_variant_grid_matrix 断言，防两处名单漂移）。
static func variant_ids() -> Array[String]:
	var out: Array[String] = []
	for id in _variants():
		out.append(String(id))
	out.sort()
	return out


## 三态查询：OK / DEGRADED / DISABLED。未知变体 / 未知网格族一律 DISABLED（不崩、不猜）。
static func status(variant_id: String, grid_kind: String) -> String:
	if not _variants().has(variant_id):
		return DISABLED
	if not is_known_grid_kind(grid_kind):
		return DISABLED
	if grid_kind == RECT:
		return OK
	if grid_kind == MASK:
		# 容器族：取 style 三族里最保守的状态。
		var worst := OK
		for style_kind in MASK_STYLE_KINDS:
			worst = _worse(worst, status(variant_id, str(style_kind)))
		return worst
	var info: Dictionary = _variants()[variant_id]
	if str(info["geometry"]) == "generic":
		return OK
	# 非 GENERIC（GEO_RECT_ONLY）⇒ 生成期异形门控会拦住它（线索型回退 classic / 全局约束型丢弃，
	# 判据同 `supports_topology()`，core/puzzle_generator.gd:463-498）⇒ 一律 DISABLED。
	# DEGRADED 只在「该族上**仍有**可解释的较弱语义」时才给（须带非空退化清单，见 degradations()）。
	if _degradations_of(info, grid_kind).is_empty():
		return DISABLED
	return DEGRADED


## 用户可读原因。OK 返回空串；DEGRADED / DISABLED（含未知变体、未知网格族）必须非空。
static func reason(variant_id: String, grid_kind: String) -> String:
	if not _variants().has(variant_id):
		return "未登记的变体 id「%s」：矩阵只覆盖 VariantRegistry.all_codes() 的内置变体，未知变体一律禁用（不猜语义）。" % variant_id
	if not is_known_grid_kind(grid_kind):
		return "未登记的网格族「%s」：仓库里真实存在的只有 %s；不存在的族（如 Voronoi / 布尔复合格）一律禁用。" % [
			grid_kind, str(grid_kinds())]
	var st := status(variant_id, grid_kind)
	if st == OK:
		return ""
	var info: Dictionary = _variants()[variant_id]
	var semantics := str(info["semantics"])
	var evidence := str(info["evidence"])
	if grid_kind == MASK:
		var worst_style := _worst_mask_style(variant_id)
		return "轮廓族 mask 的几何由 style 继承（%s）；本格取三者中最保守者「%s」——%s" % [
			str(MASK_STYLE_KINDS), worst_style, reason(variant_id, worst_style)]
	if st == DEGRADED:
		return "退化可用：「%s」在 %s 上仍可解释为较弱语义，但覆盖不完整（受影响语义见 degradations()）；该变体声明仅矩形几何（%s）。" % [
			semantics, grid_kind, evidence]
	if str(info["role"]) == "clue":
		return "禁用：该变体是线索型，依赖固定方向 / 环序（%s）；%s 是邻接表盘（core/board.gd:164-171 走 AdjacencyGrid），生成期会把线索规则回退成经典并告警（core/puzzle_generator.gd:463-472），载入期 compute_clue_topo 也退化为基类默认的拓扑邻域计数（core/board.gd:283-284 + core/rule_plugin.gd:171-178）⇒ 勾选后不生效。" % [
			evidence, grid_kind]
	# 全局约束型：门控与线索型同判据（supports_topology），但**没有「经典」可替换**
	# ⇒ 生成期的安全回退是「丢弃该约束（等价于未勾选）+ 告警」，落盘 global_rules 同步（不许自述带未生效约束）。
	return "禁用：该变体的约束按「%s」定义（%s），而 %s 上不存在%s——按包围盒坐标强算（core/rule_builder.gd:56-59）会得到另一个约束，故生成期会丢弃该全局规则并告警（core/puzzle_generator.gd:473-498）⇒ 勾选后不生效。" % [
		semantics, evidence, grid_kind, _missing_axis_clause(grid_kind)]


## 受影响语义清单。**非空 ⟺ status == DEGRADED**（门禁据此显示「退化说明」）。
## 【2026-10-03 门控补齐后】本表**无 DEGRADED 格** ⇒ 恒返回空（见文件头三态判据）。
## 保留接口 = 三态契约的一部分：将来某格确有可解释的弱语义时，须同时改 status() 与
## _variants() 的 bbox_degradations / wrap_degradations（test 对全表断言此充要关系）。
static func degradations(variant_id: String, grid_kind: String) -> Array[String]:
	var out: Array[String] = []
	if status(variant_id, grid_kind) != DEGRADED:
		return out
	if grid_kind == MASK:
		var style_kind := _worst_mask_style(variant_id)
		out.assign(degradations(variant_id, style_kind))
		return out
	out.assign(_degradations_of(_variants()[variant_id], grid_kind))
	return out


## 该网格族上可选（OK + DEGRADED）的变体，顺序 = `VariantRegistry.all_codes()`。
static func enabled_variants(grid_kind: String) -> Array[String]:
	var out: Array[String] = []
	for id in VariantRegistry.all_codes():
		if status(id, grid_kind) != DISABLED:
			out.append(id)
	return out


## 该网格族上被禁用（DISABLED）的变体，顺序 = `VariantRegistry.all_codes()`。
static func disabled_variants(grid_kind: String) -> Array[String]:
	var out: Array[String] = []
	for id in VariantRegistry.all_codes():
		if status(id, grid_kind) == DISABLED:
			out.append(id)
	return out


## 物化整张表（供门禁/工具一次性读取）：{variant_id: {grid_kind: status}}。
static func table() -> Dictionary:
	var out := {}
	for id in VariantRegistry.all_codes():
		var row := {}
		for k in ALL_KINDS:
			row[str(k)] = status(id, str(k))
		out[id] = row
	return out


# ==================== 内部 ====================

## 变体声明表：id -> {name, role, geometry, semantics, evidence, bbox_degradations, wrap_degradations}
##   role     —— "clue"（线索型）/ "global"（全局约束型）
##   geometry —— "generic"（GEO_ADJ_GENERIC，任意拓扑可用）/ "rect_only"（GEO_RECT_ONLY）
## evidence 逐项引用**实现处**（声明或约束构造的那几行），改规则时这里也要跟着改。
static func _variants() -> Dictionary:
	return {
		# ---- 唯一声明任意拓扑可用的变体 ----
		"classic": {
			"name": "经典", "role": "clue", "geometry": "generic",
			"semantics": "数字 = 拓扑邻域雷数（矩形盘上即 Moore 8 邻）",
			"evidence": "core/rule_registry.gd:171-175（GEO_ADJ_GENERIC；拓扑非空时 b.neighbors 直接返回邻接表，core/rule_builder.gd:77-85）",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		# ---- 7 个线索型（全部仅矩形）----
		"4n": {
			"name": "四邻", "role": "clue", "geometry": "rect_only",
			"semantics": "数字 = 上下左右 4 格雷数（固定正交偏移）",
			"evidence": "demo/mods/legacy_rules/entry.gd:40-45；未覆写 geometry_kind ⇒ 基类默认 RECT_ONLY（core/rule_plugin.gd:52-53）",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"clock": {
			"name": "钟点", "role": "clue", "geometry": "rect_only",
			"semantics": "数字 = 8 邻顺时针首个雷方位（1~8），无雷 = 0",
			"evidence": "core/rule_registry.gd:510-513（值 = ClueEngine.ring_dirs 的固定环序索引）",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"hv": {
			"name": "纵横分计", "role": "clue", "geometry": "rect_only",
			"semantics": "每格双值：正交雷数 + 对角雷数",
			"evidence": "demo/mods/legacy_rules/entry.gd:225-231（b.neighbors 用正交 / 对角偏移）；基类默认 RECT_ONLY",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"fr": {
			"name": "首雷", "role": "clue", "geometry": "rect_only",
			"semantics": "数字 = 向右第一颗雷的距离（格数），无雷 = inf",
			"evidence": "demo/mods/legacy_rules/entry.gd:138-150（pos.x+1 … b.cols 逐列取格）",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"loopruns": {
			"name": "环游程", "role": "clue", "geometry": "rect_only",
			"semantics": "数字 = 8 邻环序连续雷段数（环序首尾相接）",
			"evidence": "core/rule_registry.gd:558-561（游程按固定环序取 prev = cells[(i-1+n)%n]）",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"distsum": {
			"name": "曼哈顿和", "role": "clue", "geometry": "rect_only",
			"semantics": "数字 = 邻域雷的曼哈顿距离加权和（正交 1 + 对角 2）",
			"evidence": "demo/mods/legacy_rules/entry.gd:169-201（pos + d 逐偏移取值、权重按几何距离）；test/unit/test_topology_matrix.gd:20-24 已列其为异形盘「不适用」样例",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"sc": {
			"name": "同色", "role": "clue", "geometry": "rect_only",
			"semantics": "数字 = 对角 4 格雷数",
			"evidence": "demo/mods/legacy_rules/entry.gd:74-79（ClueEngine.diagonal_dirs）",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		# ---- 7 个全局约束型（全部仅矩形；异形族上一律 DISABLED）----
		#
		# 【2026-10-03 门控补齐：DEGRADED → DISABLED，原「退化清单」删除】
		# 这 7 条此前在缺格族（BBOX_SUBSET_KINDS）/ 环绕族上是 DEGRADED，理由是「生成期没有全局门控
		# ⇒ 约束被原样构建 ⇒ 按包围盒强算的弱语义确有其事」。现在生成期对全局约束型也做门控
		#（core/puzzle_generator.gd:473-498）：RECT_ONLY 的全局规则在拓扑盘上被**丢弃**（等价于未勾选）
		# 并大声告警 ⇒ 弱语义不再存在 ⇒ 全部转 DISABLED（原因见 reason()）。
		# 逐条「为何该约束在异形盘上没有几何对应」见各规则自己的 geometry_kind() 注释
		#（core/rule_registry.gd / demo/mods/legacy_rules/entry.gd，evidence 字段即指向那里）。
		"mx": {
			"name": "镜像", "role": "global", "geometry": "rect_only",
			"semantics": "雷区左右镜像对称（列配对 c ↔ cols-1-c）",
			"evidence": "core/rule_registry.gd:211-219",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"rl": {
			"name": "相邻行锁", "role": "global", "geometry": "rect_only",
			"semantics": "相邻两行雷数差为 1",
			"evidence": "core/rule_registry.gd:624-639",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"pf": {
			"name": "局部禁形", "role": "global", "geometry": "rect_only",
			"semantics": "任意 2×2 方块至多 2 雷",
			"evidence": "core/rule_registry.gd:287-299",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"qd": {
			"name": "四象", "role": "global", "geometry": "rect_only",
			"semantics": "四象限雷数相等（中央行列除外）",
			"evidence": "core/rule_registry.gd:707-721（ConstraintEngine.quadrant_of(r, c, rows, cols)）",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"dt": {
			"name": "骨牌边界", "role": "global", "geometry": "rect_only",
			"semantics": "每块 2×1 骨牌恰 1 雷",
			"evidence": "core/rule_registry.gd:782-799（骨牌划分由 place_mines 按 r / c 扫描生成并持有）",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"ep": {
			"name": "端点平衡", "role": "global", "geometry": "rect_only",
			"semantics": "最左列与最右列雷数相等",
			"evidence": "demo/mods/legacy_rules/entry.gd:261-269（取包围盒的 0 与 cols-1 列）",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
		"4c": {
			"name": "四向守恒", "role": "global", "geometry": "rect_only",
			"semantics": "黑格 (c+r) 偶 与白格雷数相等",
			"evidence": "demo/mods/legacy_rules/entry.gd:317-326",
			"bbox_degradations": [],
			"wrap_degradations": [],
		},
	}


## DISABLED 原因里的「缺失的几何轴」一句——按族给，避免把环绕盘说成「有缺格」。
## 缺格族（BBOX_SUBSET_KINDS）与其余异形族几何问题不同源，文案也要不同源。
static func _missing_axis_clause(grid_kind: String) -> String:
	if BBOX_SUBSET_KINDS.has(grid_kind):
		return "对应的行 / 列 / 2×2 窗口 / 中轴 / 染色几何轴（缺格：洞格 / 轮廓外格使包围盒坐标轴与盘面几何轴不再重合）"
	if grid_kind == RECT_WRAP:
		return "对应的行 / 列 / 2×2 窗口 / 中轴 / 染色几何轴（环绕折返：环上没有几何意义上的首末列、接缝与上下界）"
	return "对应的行 / 列 / 2×2 窗口 / 中轴 / 染色几何轴"


static func _degradations_of(info: Dictionary, grid_kind: String) -> Array:
	# DEGRADED 契约的载体：条目自带可解释弱语义时填 bbox_/wrap_degradations（非空 ⇒ status() 给 DEGRADED）。
	# 【2026-10-03 门控补齐后】本表全部条目均为空 ⇒ 非矩形族一律 DISABLED（见文件头三态判据）。
	# 缺格类（holed_grid / circle / star / sector）：退化理由同为「按包围盒强算、盘外格 = 0」，
	# 措辞已统一为「缺格（洞格 / 轮廓外格）」⇒ 可共用同一份 bbox_degradations。
	if BBOX_SUBSET_KINDS.has(grid_kind):
		return info.get("bbox_degradations", [])
	if grid_kind == RECT_WRAP:
		return info.get("wrap_degradations", [])
	return []


## mask 上最保守的 style（严重度最高者；同严重度取 MASK_STYLE_KINDS 里的前者）。
static func _worst_mask_style(variant_id: String) -> String:
	var worst := str(MASK_STYLE_KINDS[0])
	for style_kind in MASK_STYLE_KINDS:
		var k := str(style_kind)
		if _severity(status(variant_id, k)) > _severity(status(variant_id, worst)):
			worst = k
	return worst


static func _worse(a: String, b: String) -> String:
	return b if _severity(b) > _severity(a) else a


static func _severity(s: String) -> int:
	match s:
		OK:
			return 0
		DEGRADED:
			return 1
		_:
			return 2
