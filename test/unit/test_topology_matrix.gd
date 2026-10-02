# test_topology_matrix.gd —— 「棋盘 × 算子」矩阵：把「两边都可行、组合却被判不可行」变成会红的断言
#
# 要治的现象（用户点名）：异形棋盘可用、变体也可用，但平台把两者的组合判成「不可行」——
# 判据层用矩形模型算（中轴/骨牌/行列），生成期却强制把非 classic 线索降级成 classic。
# 于是同一个组合在两处得到相反结论，而且没有任何测试会红。
#
# 本文件把矩阵逐格钉死：**3 类棋盘 × 4 类算子 = 12 格**，每格只能落进两类之一，且必须带原因：
#   · 可用        —— 且「带该拓扑的 CP-SAT 判可行」⟺「生成期判据不判不可行」
#                    （I1 不变量：生成期判可行 ⇒ RuleFeasibility.query_topo 不许说不可行）
#   · 不适用(原因) —— 来自规则自己的 geometry_kind() 声明 / compat_all 的 WARN 原因，
#                    **绝不允许**表现为「不可行」，也绝不允许 FORBID
#
# 棋盘（全部由 core/adjacency_builder.gd 现场构造，不依赖任何用户资产 / 关卡文件）：
#   ① rect  6×6（Moore 8 邻，平台矩形语义）
#   ② hex   size=7（37 格蜂窝；邻接由共边推导）
#   ③ mixed 4×4（3.6.3.6 六边形 + 三角形混合镶嵌；邻接由共边推导）
#
# 算子（按类别取，均用注册表里的**真实规则**，不造假规则）：
#   ① 邻域计数型 classic（声明 GEO_ADJ_GENERIC）
#   ② 加权型      o4 / distsum（任取其一）——**本轮两者都是「不适用」的正面样例**：
#                 o4 的约束走 `b.neighbors(pos, N2_OUT)`（切比雪夫环-2 外壳），而拓扑下
#                 RuleBuilder.neighbors 忽略 dirs、只返回 1 跳邻接表（core/rule_builder.gd:77-85）；
#                 distsum 用 pos+d 逐偏移取变量（不走 b.neighbors）且权重 1/2 依赖几何距离。
#                 两者要让上异形盘须新增「k 跳/环壳」原语 + 各自约束重写，不是加个 flag（impl-topo 口径）。
#   ③ 方向型      clock / fr / loopruns（任取其一）
#   ④ 几何依赖型  qd / mx / dt（任取其一）
#
# 预期由**规则自己的声明 + 棋盘的结构标注**推出（不写死答案表）：
#   矩形盘        ⇒ 自带行列/方向语义 ⇒ 任何算子「可用」；
#   非矩形盘：邻域计数型（classic、规格 refs="topo"）⇒ 任何连通盘「可用」；
#             加权 / 对角 / 同色 / 方向 / 环序 ⇒ 必须 ① 规则声明 supports_topology()
#             **且** ② 盘上有边类型标注（board.json 的 "kind"，见 core/adjacency_builder.gd:25-31）；
#             缺任一 ⇒ **不适用（原因）**；
#             对称 / 中轴 / 象限 / 骨牌 ⇒ 需要矩形或显式结构标注，否则同样**不适用（原因）**。
# 「不适用」与「不可行」是两件事：本文件对第 ③④ 类算子在非矩形盘上**只允许**前者的表述，
# 且断言原因字符串非空、不含「不可行」、`compat_all` 不为 FORBID——但按 impl-topo 的精确不变量收窄：
#   异形盘（cells ≠ 包围盒面积）上 compat_all 的 FORBID 只可能来自
#     R0（同算子 / 重复 id）、R4（逻辑蕴含冗余）、非几何整除 R5（Div.MOD_EQ / Div.EVEN）；
#   几何依赖项（Div.MOD_EQ_MINUS_C / Div.EXACT_HALF）与 D4 对称 R3 一律降级 WARN，绝不 FORBID。
#   ⇒ 命中 R0/R4/非几何 R5 的 FORBID 属正确结论，不作断言（见 _allow_forbid_on_irregular）。
#   `compat_all` v4.x 起 FORBID 的 `rules` 是**结构化判据码数组**（core/rule_signature.gd:237-242），
#   降级 WARN 时 `rules == []` ⇒ 本文件按码判定，不做文案匹配。
# 特别地，第 ③ 类（方向型）在**未标注边类型**的盘上必须判「不适用」（原因=棋盘未提供方向语义
# 标注）——即使它声明了 GEO_ADJ_GENERIC：纯邻接表里没有「哪条边是对角/环向」的信息。
# 因此本测试的红 == 声明/平台行为与上述适用性规则矛盾。
#
# 墙钟纪律：CP-SAT 调用少量（每格 1 尺寸 + 1 雷数，且 RuleFeasibility 自带缓存）；
# 真生成探测（test_classic_generation_agrees_with_cpsat）只在 CP-SAT 可用时跑，
# 且只对 classic 一列（最便宜），最多 3 盘 × 3 seed，单次 8s 预算。
#
# 矩阵之外另有五条断言：盘面自证（契约/连通/格数）、边类型标注自证、**几何依赖两算子组合不变量**
# （异形盘上必须 WARN、不得 FORBID、`rules` 为空——覆盖 T3/T7 的单算子盲区）、
# 所有声明支持拓扑的线索规则的归纳断言、classic 的真生成 ⟺ CP-SAT 一致性。
#
# 依赖的并行 API（impl-spec / impl-topo；均已落地）：
#   RuleFeasibility.resolve_mines_topo / query_topo / board_key
#   RuleSignature.compat_all(ids, size, mines, cells)
#   RulePlugin.geometry_kind() / supports_topology()（core/rule_plugin.gd:47-58）
extends GutTest

## 加权型候选（产品默认不加载 demo mod；本文件会按需装配，见 _resolve_rule）。
const WEIGHTED_CANDIDATES: Array[String] = ["o4", "distsum"]
## 方向型候选（clock 是内置，必在）。
const DIRECTION_CANDIDATES: Array[String] = ["clock", "fr", "loopruns"]
## 几何依赖型候选（qd 是内置，必在）。
const GEOMETRIC_CANDIDATES: Array[String] = ["qd", "mx", "dt"]

var _boards: Dictionary = {}
var _op_weighted := ""
var _op_direction := ""
var _op_geometric := ""


func before_all() -> void:
	_op_weighted = _first_registered(WEIGHTED_CANDIDATES)
	_op_direction = _first_registered(DIRECTION_CANDIDATES)
	_op_geometric = _first_registered(GEOMETRIC_CANDIDATES)
	# 缓存隔离：矩阵要在干净结论上跑（上一次测试残留的缓存会掩盖「棋盘指纹没进键」的问题）。
	RuleFeasibility.clear_cache()


func before_each() -> void:
	RuleFeasibility.clear_cache()


# ==================== 棋盘自证 ====================

func test_boards_are_well_formed_and_connected() -> void:
	var specs := {"rect": 36, "hex": -1, "mixed": -1}
	for key in specs:
		var board := _board(key)
		assert_not_null(board["topo"], "%s 棋盘应能构造（AdjacencyBuilder.from_tiling）" % key)
		if board["topo"] == null:
			continue
		var audit: Dictionary = AdjacencyBuilder.audit(board["topo"])
		assert_true(bool(audit["ok"]), "%s 棋盘必须满足 AdjacencyGrid 契约：%s" % [key, str(audit["problems"])])
		var n := int(audit["cell_count"])
		if int(specs[key]) > 0:
			assert_eq(n, int(specs[key]), "%s 棋盘格数" % key)
		else:
			assert_gte(n, 20, "%s（异形盘）格数应 ≥ 20，矩阵才有意义" % key)
		# 不连通盘会让「序贯可解」必然失败 —— 矩阵用盘必须连通（与 board_validate 的判据同源）
		assert_eq(_components(board["topo"]).size(), 1, "%s 棋盘必须连通" % key)


## 结构标注自证：rect tiling 由平台按 Moore 偏移自动标注 ortho/diag；
## hex / mixed 只有邻接表 ⇒ 全部边「未标注」。这条正是方向/对角/环序类算子在它们上面
## 落「不适用」的**唯一依据**——把它单独钉住，免得将来某次改动悄悄把标注丢了。
func test_edge_kind_annotation_is_reported_by_audit() -> void:
	var rect := _board("rect")
	assert_true(bool(rect["annotated"]), "rect tiling 应带边类型标注（ortho/diag）")
	var a_rect: Dictionary = AdjacencyBuilder.audit(rect["topo"])
	assert_eq(int(a_rect["untyped_edges"]), 0, "rect tiling 不应有未标注边")
	var hist: Dictionary = a_rect["edge_kind_hist"]
	assert_true(hist.has("ortho") and hist.has("diag"), "rect tiling 应同时有 ortho 与 diag：%s" % str(hist))
	for key in ["hex", "mixed"]:
		var b := _board(key)
		assert_false(bool(b["annotated"]), "%s 盘未提供边类型标注（只有邻接表）" % key)
		var a: Dictionary = AdjacencyBuilder.audit(b["topo"])
		assert_eq(int(a["untyped_edges"]), int(a["edge_count"]),
				"%s 盘的全部边都应记为未标注（方向语义不可求值）" % key)


## 组合不变量：**两个几何依赖算子叠加**在异形盘上仍必须 WARN、不得 FORBID，且 `compat_all` 的
## `rules` 为空（纯几何降级、无算子代数码）。这条提供 T3/T7（单算子）与矩阵单算子格**之外的覆盖**
## ——它正是本批要治的缺陷形态：「两边各自可行、组合却被判不可行」。
func test_geometry_dependent_pair_on_irregular_is_warn_not_forbid() -> void:
	var pair: Array[String] = []
	for cand in ["dt", "qd"]:
		if _resolve_rule(cand) != null:
			pair.append(cand)
	assert_gte(pair.size(), 2, "需要 dt（骨牌 EXACT_HALF）与 qd（中轴 MOD_EQ_MINUS_C）都在场才能钉组合不变量")
	if pair.size() < 2:
		return
	for key in ["hex", "mixed"]:
		var board := _board(key)
		var topo: GridInterface = board["topo"]
		var size: Vector2i = board["size"]
		var mines := RuleFeasibility.standard_mines(size.x)
		var comp: Dictionary = RuleSignature.compat_all(pair, size, mines, topo.cell_count())
		var verdict := str(comp["verdict"])
		var rules: Array = comp.get("rules", [])
		var reason := str(comp.get("reason", ""))
		assert_ne(verdict, RuleSignature.FORBID,
				"两个几何依赖算子叠加在异形盘上不得判「不可行」/FORBID：%s × %s（%s）" % [str(pair), key, reason])
		assert_true(reason.contains("异形盘不适用"),
				"几何项降级必须写明「异形盘不适用」：%s × %s（%s）" % [str(pair), key, reason])
		# 区分信号（impl-topo 口径）：compat_all 的降级 WARN 恒不带码；一旦带码说明命中了算子代数判据。
		assert_true(rules.is_empty(),
				"compat_all 的降级 WARN 不得携带判据码（纯净几何降级）：%s × %s（%s）" % [str(pair), key, str(rules)])
		# 逐对精确口径：码在 compat() 层是精确的，它也必须在异形盘上保持 not FORBID。
		var pair_comp: Dictionary = RuleSignature.compat(pair[0], pair[1], size, mines, topo.cell_count())
		assert_ne(str(pair_comp["verdict"]), RuleSignature.FORBID,
				"compat(%s, %s) 在异形盘上不得 FORBID（%s）" % [pair[0], pair[1], str(pair_comp.get("reason", ""))])
		print("    [组合] %s × %s：compat_all=%s rules=%s（不得 FORBID）" % [
			str(pair), key, verdict, str(rules)])


# ==================== 矩阵三行 ====================

func test_matrix_rect_6x6() -> void:
	_check_board(_board("rect"), true)


func test_matrix_hex_size7() -> void:
	_check_board(_board("hex"), false)


func test_matrix_mixed_hex_tri() -> void:
	_check_board(_board("mixed"), false)


# ==================== 归纳断言（防止矩阵空转） ====================

## 邻域计数型必须声明为任意棋盘可用。若它被判 GEO_RECT_ONLY，异形盘上连 classic 都会「不适用」，
## 整个矩阵会退化成一片「不适用」而**看起来全绿**——必须单独钉住这一条。
func test_neighborhood_counting_declares_generic() -> void:
	var classic := _resolve_rule("classic")
	assert_not_null(classic, "classic 必须在场")
	if classic == null:
		return
	assert_eq(int(classic.geometry_kind()), RulePlugin.GEO_ADJ_GENERIC,
			"classic 只依赖拓扑邻域，必须声明 GEO_ADJ_GENERIC")
	assert_true(bool(classic.supports_topology()), "classic 必须支持任意拓扑（否则异形盘永远只能降级）")


## 归纳：所有「声明支持任意拓扑」的线索规则，在蜂窝与混合镶嵌盘上都必须「可用」——
## 而不是被任何一层判成「不可行」。新算子只要声明 GEO_ADJ_GENERIC 就自动被这条覆盖。
func test_every_generic_clue_rule_is_usable_on_irregular_boards() -> void:
	var checked := 0
	for rid in RuleRegistry.default().all_ids():
		var rule: Object = RuleRegistry.default().resolve(rid)
		if rule == null or not rule.has_method("supports_topology"):
			continue
		if rule.get_kind() != RulePlugin.KIND_CLUE or not bool(rule.supports_topology()):
			continue
		checked += 1
		for key in ["hex", "mixed"]:
			var board := _board(key)
			var rres: Dictionary = RuleFeasibility.resolve_mines_topo(String(rid), [], board["topo"])
			var mines := int(rres.get("mines", -1))
			assert_gt(mines, 0, "「%s × %s」声明支持任意拓扑，就必须能给出可用雷数（实际 %s）" % [
				String(rid), key, str(rres)])
			if mines <= 0:
				continue
			assert_true(RuleFeasibility.query_topo(String(rid), [], board["topo"], mines),
					"I1：生成期判可行 ⇒ query_topo 不许说不可行（%s × %s，mines=%d）" % [
						String(rid), key, mines])
	assert_gt(checked, 0, "至少应有 classic 一个 GEO_ADJ_GENERIC 线索规则（否则矩阵空转）")


## 「CP-SAT 判可行 ⟺ 生成器不判不可行」的真生成探测（只跑 classic 一列，控墙钟）。
## 这正是「两边可行、组合被判不可行」的最终用户可见形态：判据说可行、生成器却永远返回空。
func test_classic_generation_agrees_with_cpsat() -> void:
	if not RuleCpSat.available():
		pending("CP-SAT 后端不可用（缺 .NET/mono 运行时）：无法做真生成探测，跳过")
		return
	for key in ["rect", "hex", "mixed"]:
		var board := _board(key)
		var rres: Dictionary = RuleFeasibility.resolve_mines_topo("classic", [], board["topo"])
		var mines := int(rres.get("mines", -1))
		assert_gt(mines, 0, "%s 盘上 classic 应给出可用雷数（实际 %s）" % [key, str(rres)])
		if mines <= 0:
			continue
		var cp_sat_ok := RuleFeasibility.query_topo("classic", [], board["topo"], mines)
		var gen := PuzzleGenerator.new()
		gen.num_workers = 1
		var generated := false
		for seed in range(1, 4):
			var lv: Dictionary = gen.generate_with_rules("classic", [], (board["topo"] as GridInterface).size(),
					mines, seed, 0, 3, board["topo"], 8000)
			if not lv.is_empty():
				generated = true
				break
		assert_eq(generated, cp_sat_ok,
				"「CP-SAT 判可行 ⟺ 生成器不判不可行」在 %s 上必须成立（cp_sat=%s, 生成=%s, mines=%d）" % [
					key, str(cp_sat_ok), str(generated), mines])


# ==================== 矩阵单元判定 ====================

## 逐格判定。is_rect = 该盘本身就是矩形（此时 GEO_RECT_ONLY 也算「适用」）。
func _check_board(board: Dictionary, is_rect: bool) -> void:
	var topo: GridInterface = board["topo"]
	if topo == null:
		fail_test("%s 棋盘构造失败，矩阵无法判定" % board["name"])
		return
	var size: Vector2i = board["size"]
	var annotated := bool(board["annotated"])
	var ops: Array = [
		{"id": "classic", "cat": "adj_count"},
		{"id": _op_weighted, "cat": "weighted"},
		{"id": _op_direction, "cat": "direction"},
		{"id": _op_geometric, "cat": "geometric"},
	]
	if _op_weighted == "" or _op_direction == "" or _op_geometric == "":
		fail_test("矩阵算子未取齐：加权=%s 方向=%s 几何=%s（见 _resolve_rule 的装配目录）" % [
			_op_weighted, _op_direction, _op_geometric])
		return
	for cell: Dictionary in ops:
		var op := str(cell["id"])
		var cat := str(cell["cat"])
		var rule: Object = _resolve_rule(op)
		assert_not_null(rule, "算子 %s 必须已注册（矩阵要取它的几何声明）" % op)
		if rule == null:
			continue
		var kind := int(rule.geometry_kind())
		# 适用性规则（见文件头）：矩形盘全适用；非矩形盘只放行「只用邻域计数」，
		# 需要方向/对角/距离/环序语义的算子还必须要求盘上有边类型标注。
		var needs_semantics := cat != "adj_count"
		var usable := is_rect or (kind == RulePlugin.GEO_ADJ_GENERIC and (not needs_semantics or annotated))
		if usable:
			_assert_cell_usable(board, size, op, rule, is_rect)
		else:
			_assert_cell_not_applicable(board, size, op, rule, cat, annotated)


## 「可用」格：CP-SAT 判可行 ⟺ 生成期可行；并附 I1 不变量与 compat_all 不许 FORBID。
func _assert_cell_usable(board: Dictionary, size: Vector2i, op: String, rule: Object, is_rect: bool) -> void:
	if not is_rect:
		assert_true(bool(rule.supports_topology()),
				"%s 在异形盘上被判「可用」，就必须声明 supports_topology()（否则生成期会偷偷回退 classic）" % op)
	var rres: Dictionary = RuleFeasibility.resolve_mines_topo(op, [], board["topo"])
	var mines := int(rres.get("mines", -1))
	if mines <= 0:
		# 异形盘 + 声明 GENERIC 却拿不到雷数 = 正是要治的缺陷，必须红。
		# 矩形盘上的 RECT_ONLY 算子不可行是「该尺寸无解」的数学结论（不属于矩阵判定对象），
		# 只如实打印——矩阵判定的是**适用性分类**，不是每个尺寸的数学可解性。
		if is_rect:
			print("    [可用] %s × %s：该尺寸下数学不可行（矩形口径结论，非矩阵判定对象）：%s" % [
				op, board["name"], str(rres)])
			return
		assert_gt(mines, 0, "「%s × %s」声明支持任意拓扑，却拿不到可用雷数：%s" % [
			op, board["name"], str(rres)])
		return
	# ⟺：生成期可行性判据（mines > 0）与带拓扑的 CP-SAT 结论必须同向
	var cpsat := RuleFeasibility.query_topo(op, [], board["topo"], mines)
	assert_true(cpsat, "I1：生成期判可行（mines=%d）⇒ query_topo 不许说不可行（%s × %s）" % [
		mines, op, board["name"]])
	assert_eq(cpsat, mines > 0,
			"「两边可行 ⟺ 生成器不判不可行」被打破：%s × %s（cpsat=%s, mines=%d）" % [
				op, board["name"], str(cpsat), mines])
	# 结构判据不得把可用组合判成 FORBID——但这条保证**有边界**（impl-topo 口径）：
	#   · 只在**异形盘**（cells ≠ 包围盒面积）上成立：那时几何依赖项被降级为 WARN；
	#     矩形盘上 R5 用的是正确的矩形模型，FORBID 属正常结论，不在此断言；
	#   · 且只在算子签名**没有**与几何无关的整除项时成立（`4c` 的 EVEN、`grpk` 的 MOD_EQ 会
	#     因 N 奇偶/倍数独立判 FORBID，那与棋盘几何无关，见 core/rule_signature.gd:46-52）。
	# 另：无 CP-SAT 后端时 RuleFeasibility 乐观放行（core/rule_feasibility.gd 的 unknown/无全局
	# ⇒ true），与 compat_all 的保守判决本就不可比，硬断言会造出与缺陷无关的假红。
	var ids: Array[String] = [op]
	var comp: Dictionary = RuleSignature.compat_all(ids, size, mines, board["topo"].cell_count())
	var verdict := str(comp["verdict"])
	if RuleCpSat.available() and not is_rect and not _allow_forbid_on_irregular(op, comp):
		assert_ne(verdict, RuleSignature.FORBID,
				"异形盘上的可用组合不得被结构判据判 FORBID：%s × %s（%s）" % [op, board["name"], str(comp.get("reason", ""))])
	else:
		print("      （compat_all=%s，仅作诊断：%s）" % [verdict,
				"矩形盘/无后端/命中 R0·R4·非几何 R5" if is_rect or not RuleCpSat.available() \
						or _allow_forbid_on_irregular(op, comp) else "诊断"])
	assert_ne(RuleFeasibility.board_key(board["topo"]), "", "棋盘指纹不得为空（缓存键依赖它）")
	print("    [可用] %s × %s（mines=%d, kind=GEO_ADJ_GENERIC%s）" % [
		op, board["name"], mines, "" if not is_rect else "/矩形盘"])


## 「不适用」格：原因必须来自几何声明 / 边类型缺失 / compat_all WARN，且**绝不允许**表现为「不可行」。
## cat = 算子类别（weighted / direction / geometric）；annotated = 盘上是否有边类型标注。
## 本函数**只在非矩形盘上被调用**（矩形盘一律走「可用」分支），所以这里的每一条断言都在
## 「异形盘」语境下成立。
func _assert_cell_not_applicable(board: Dictionary, size: Vector2i, op: String, rule: Object,
		cat: String, annotated: bool) -> void:
	var kind := int(rule.geometry_kind())
	if kind == RulePlugin.GEO_RECT_ONLY:
		assert_false(bool(rule.supports_topology()),
				"%s 声明 GEO_RECT_ONLY 时 supports_topology() 必须为 false（生成期据此回退 classic）" % op)
	else:
		# 声明了 GENERIC 却仍落入「不适用」⇒ 只能是盘缺结构标注（本矩阵的所有异形盘都没标 kind）。
		assert_false(annotated,
				"%s 声明 GEO_ADJ_GENERIC，在**已标注**边类型的非矩形盘上应判「可用」，不该是「不适用」" % op)
		assert_true(cat != "adj_count",
				"只依赖邻域计数的算子（%s）在连通盘上不该落入「不适用」" % op)
	var ids: Array[String] = [op]
	var comp: Dictionary = RuleSignature.compat_all(ids, size, RuleFeasibility.standard_mines(size.x),
			board["topo"].cell_count())
	var reason := str(comp.get("reason", ""))
	if reason == "":
		if kind == RulePlugin.GEO_RECT_ONLY:
			reason = "该变体声明依赖矩形几何（geometry_kind=GEO_RECT_ONLY），异形棋盘上不适用"
		else:
			reason = "棋盘未提供方向语义标注（边未标 kind）——需要方向/对角/环序语义的算子无法在纯邻接表上求值"
	assert_ne(reason.strip_edges(), "", "「不适用」必须给出原因字符串")
	# 核心 #1：不适用 ≠ 不可行。按 impl-topo 给出的精确不变量收窄断言——异形盘上 compat_all 的
	# FORBID 只可能来自 R0（同算子/未知签名）、R4（逻辑蕴含冗余）、非几何整除 R5（MOD_EQ / EVEN）；
	# 几何依赖项（MOD_EQ_MINUS_C / EXACT_HALF）与 D4 对称 R3 一律降级 WARN，绝不 FORBID。
	if _allow_forbid_on_irregular(op, comp):
		print("      （%s：FORBID=%s 来自 R0/R4/非几何 R5，与棋盘几何无关，不作断言）" % [
			op, str(comp["verdict"])])
	else:
		assert_ne(str(comp["verdict"]), RuleSignature.FORBID,
				"「不适用」绝不允许表现为「不可行」/FORBID：%s × %s（%s）" % [op, board["name"], reason])
	assert_false(reason.contains("不可行"),
			"「不适用」的原因字符串里不许出现「不可行」：%s × %s（%s）" % [op, board["name"], reason])
	# 核心 #2：第 ③ 类（方向型）在未标注边类型的盘上必须判「不适用」，
	# 且原因必须落到「几何依赖」或「缺方向语义标注」之一——不能含糊成"不可用"了事。
	if cat == "direction" and not annotated:
		assert_true(reason.contains("标注") or reason.contains("几何") or reason.contains("矩形"),
				"方向型在未标注边类型的盘上判「不适用」时，原因必须指向几何依赖或缺方向语义标注：%s × %s（%s）" % [
					op, board["name"], reason])
	print("    [不适用] %s(%s) × %s 原因：%s" % [op, cat, board["name"], reason])


# ==================== 棋盘 / 算子装配 ====================

func _board(key: String) -> Dictionary:
	if _boards.has(key):
		return _boards[key]
	var topo: AdjacencyGrid = null
	match key:
		"rect":
			topo = AdjacencyBuilder.from_tiling("rect", {"rows": 6, "cols": 6})
		"hex":
			topo = AdjacencyBuilder.from_tiling("hex", {"size": 7})
		"mixed":
			topo = AdjacencyBuilder.from_tiling("mixed_hex_tri", {"cols": 4, "rows": 4})
	var rec := {
		"name": key,
		"topo": topo,
		"size": topo.size() if topo != null else Vector2i.ZERO,
		# 是否有边类型标注（board.json 的 "kind"）。rect tiling 由平台按 Moore 偏移自动标注；
		# hex / mixed 只有邻接表 ⇒ 未标注 ⇒ 方向/对角/环序类算子在它们上面「不适用」。
		"annotated": topo != null and not AdjacencyBuilder.edge_kinds_of(topo).is_empty(),
	}
	_boards[key] = rec
	return rec


## 取第一个已注册的候选算子；缺失时尝试装配对应 demo mod（产品默认不加载，测试按需装上——
## 与 test/_pre_run.gd 同径，只为让矩阵取到真实的几何声明）。
func _first_registered(cands: Array[String]) -> String:
	for id in cands:
		if _resolve_rule(id) != null:
			return id
	return ""


func _resolve_rule(id: String) -> Object:
	var r: Object = RuleRegistry.default().resolve(StringName(id))
	if r != null:
		return r
	for path in ["res://demo/mods/o4_bianjing/entry.gd", "res://demo/mods/legacy_rules/entry.gd"]:
		if not ResourceLoader.exists(path):
			continue
		var sc: Variant = load(path)
		if sc == null:
			continue
		var inst: Object = sc.new()
		if inst != null and inst.has_method("on_load"):
			inst.call("on_load")
		r = RuleRegistry.default().resolve(StringName(id))
		if r != null:
			return r
	return null


## 异形盘上是否**允许** compat_all 返回 FORBID（= 该 FORBID 与棋盘几何无关，是正确结论）。
##
## impl-topo 给出的精确不变量（口径来源，勿自行改写）：
##   异形盘（cells ≠ 包围盒面积）上 compat_all 的 FORBID 只可能来自
##     R0（同算子 / 重复 id）、R4（逻辑蕴含冗余）、非几何整除 R5（Div.MOD_EQ / Div.EVEN）；
##   几何依赖项（Div.MOD_EQ_MINUS_C / Div.EXACT_HALF）与 D4 对称 R3 一律降级 WARN，绝不 FORBID。
##
## 本函数判定「该 op + 该结果」是否落在上述三个合法来源里：
##   · `rules` 含 **R0 / R4** ⇒ 合法（`compat_all` v4.x 起 FORBID 的 `rules` 是**结构化判据码数组**，
##     见 core/rule_signature.gd:202-247；降级 WARN 时 `rules == []`）——纯结构化，不做文案匹配；
##   · R5 只给码、不给 kind ⇒ 用签名里是否有非几何整除项（MOD_EQ / EVEN）判：有则合法
##     （如 4c 的 EVEN、grpk 的 MOD_EQ）；几何依赖（MOD_EQ_MINUS_C / EXACT_HALF）在异形盘上
##     会被 compat_all 直接跳过（core/rule_signature.gd:223-228），不该出现在 FORBID 里。
func _allow_forbid_on_irregular(op: String, comp: Dictionary) -> bool:
	var rules: Array = comp.get("rules", [])
	if rules.has("R0") or rules.has("R4"):
		return true
	return _has_nongeometric_div(op)


## 该算子的签名里是否有**与棋盘几何无关**的整除项（Div.MOD_EQ / Div.EVEN；参见
## core/rule_signature.gd:46-52：几何依赖的是 MOD_EQ_MINUS_C / EXACT_HALF）。
## 有 ⇒ compat_all 的 FORBID 是「N 与该规则自身的算术冲突」，与棋盘形状无关，不该在本矩阵里
## 断言"不得 FORBID"（impl-topo 的口径：4c 的 EVEN、grpk 的 MOD_EQ 即此类）。
## 签名未知 ⇒ 返回 true（保守：不在此断言，避免把签名漂移变成假红）。
func _has_nongeometric_div(op: String) -> bool:
	var sig: Variant = RuleSignature.table().get(op, null)
	if not (sig is Dictionary):
		return true
	for d in ((sig as Dictionary).get("div", []) as Array):
		var kind := int((d as Array)[0])
		if kind == RuleSignature.Div.MOD_EQ or kind == RuleSignature.Div.EVEN:
			return true
	return false


## 邻接表 → 连通分量大小列表（矩阵用盘必须恰好 1 个分量）。
func _components(topo: GridInterface) -> Array:
	var visited := {}
	var out: Array = []
	for p in topo.all_positions():
		if visited.has(p):
			continue
		var size := 0
		var queue: Array[Vector2i] = [p]
		visited[p] = true
		while not queue.is_empty():
			var cur: Vector2i = queue.pop_back()
			size += 1
			for nb in topo.get_neighbors(cur):
				if not visited.has(nb):
					visited[nb] = true
					queue.append(nb)
		out.append(size)
	return out
