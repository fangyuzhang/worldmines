# spec_schema.gd —— 声明式变体规格（spec）v1 的校验器
#
# 为什么需要它：让创作者（及其 AI agent）只写一个 JSON 文件就能定义一条新玩法规则，
# 无需写 GDScript。规则平台的安全边界由此收敛到「一小撮可枚举的 IR 原子」：
# 校验器把写错的规格在**注册前**逐项拒绝，并给出人/AI 都能照着改的中文错误。
# 若不做这层检查，坏 spec 会被下游 catch 成「无解」而静默废关（历史坑）。
#
# 分工：
#   · 本文件只做「形状 + 引用完整性 + 几何自洽」静态检查，不产生任何 IR；
#   · 运行时 IR 组装在 core/spec_rule_plugin.gd。
#   · 主题材（clue.expr）必须是 (pos, 邻域雷集) 的纯函数，故只允许 const/ref/sum/wsum，
#     并显式禁止 aux/cell/not —— 否则「线索值」将依赖隐藏态，违反平台的可验证前提。
#
# 几何自洽（v4.x，依据 core/puzzle_generator.gd:512-522 与 core/rule_plugin.gd:140-153）：
#   异形盘上平台**不调用** compute_clue（它按矩形 grid_size/dirs 求值），而是调用规则的
#   compute_clue_topo（基类默认 = 拓扑邻域雷数；本适配器**覆写**为「按 expr 在邻接表上求值」，
#   与 build_clue_constraints 同源 ⇒ 值/约束自洽，故 topo 形态允许任意值域）。
#   clue.refs 两种形态仍必须与 geometry 显式配对，否则会被平台按错误的邻域语义使用：
#     · "topo" 邻接表形态 ⇔ geometry 只能是 adj_generic；
#     · 固定偏移 {dx,dy} 形态 ⇔ geometry 必须显式声明 rect_only。
class_name SpecSchema
extends RefCounted


const VERSION := 1

## 规格 id 前缀：避免与内置（classic/mx/…）或官方席位 id 冲突。
const ID_PREFIX := "spec_"

## clue.expr 允许的节点类型：线索值必须可无 aux 求值。
const CLUE_EXPR_TYPES := ["const", "ref", "sum", "wsum"]

## globals 允许的节点类型 = core/cp_ir.gd 的 IR 节点全集（globals 可含 aux）。
const GLOBAL_NODE_TYPES := [
	"cell", "aux", "const", "sum", "wsum", "lin", "not",
	"eq", "le", "lt", "bool_or", "bool_and", "imp", "iff", "all_diff", "enforce",
]

const GEOMETRY_VALUES := ["adj_generic", "rect_only"]

## "topo" 形态下 ref 索引不落在固定 refs 数组上，而是运行时的邻接表下标；
## 超出本格度数的索引按「无该邻居 = 0」处理（见 spec_rule_plugin），故只设一个防粗心的上界。
const TOPO_REF_MAX := 64


## 校验规格。返回 {"ok": bool, "errors": PackedStringArray, "warnings": PackedStringArray}。
## errors 为空 ⇔ ok。每条错误都写成「哪里错 + 怎么改」。
## warnings 记录「合法规格但语义有前提」的提醒（如 topo 形态下 compute_clue 无效）。
static func validate(spec: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	# 告警按结构化 {code,text} 累积，末尾派生 warnings/warning_codes 两个**同序同长**数组：
	# tools/spec_check.gd 按 code 判级（2026-10-01 起白名单为空：e2e_gap 随缺口修复退役），
	# 缺 code 时退回文案判据；新增"需升级"的 code 时同步改双方。
	var warns: Array = []

	# --- spec_version ---
	if not spec.has("spec_version"):
		errors.append("缺少 spec_version 字段——v1 规格必须写 \"spec_version\": 1")
	elif not _is_num(spec["spec_version"]) or int(spec["spec_version"]) != VERSION:
		errors.append("spec_version=%s 不受支持——当前仅支持 %d" % [str(spec["spec_version"]), VERSION])

	# --- hidden_state：v1 明确不支持 ---
	if spec.has("hidden_state"):
		errors.append("出现 hidden_state 字段——v1 不支持规格级隐藏态（隐藏态只能由插件代码声明，规格 v1 无此表达力）")

	# --- id ---
	var id := ""
	var id_ok := false
	if not spec.has("id") or not (spec["id"] is String):
		errors.append("缺少 id 字段（或类型不是字符串）——id 必须以 \"%s\" 开头" % ID_PREFIX)
	else:
		id = spec["id"]
		if not id.begins_with(ID_PREFIX):
			errors.append("id \"%s\" 必须以 \"%s\" 开头——否则会与内置/官方规则 id 冲突" % [id, ID_PREFIX])
		elif id.length() == ID_PREFIX.length():
			errors.append("id \"%s\" 在 \"%s\" 之后为空——请补一个唯一名字，如 \"%smy_rule\"" % [id, ID_PREFIX, ID_PREFIX])
		else:
			id_ok = true

	# --- title ---
	if not spec.has("title") or not (spec["title"] is String) or str(spec["title"]).strip_edges() == "":
		errors.append("缺少 title 字段（必须是非空字符串）——它用于规则图鉴显示，请写可读中文名")

	# --- geometry（缺省 adj_generic；非法值报错后仍按缺省继续做一致性检查）---
	var geo := "adj_generic"
	if spec.has("geometry"):
		if not (spec["geometry"] is String) or not GEOMETRY_VALUES.has(spec["geometry"]):
			errors.append("geometry \"%s\" 非法——只允许 %s（缺省 adj_generic：只用邻域；rect_only：依赖行列/方向/对称）" % [str(spec["geometry"]), str(GEOMETRY_VALUES)])
		else:
			geo = String(spec["geometry"])

	# --- aux ---
	var aux_size := 0
	if spec.has("aux"):
		if not (spec["aux"] is Array):
			errors.append("aux 必须是数组——每项形如 {\"kind\":\"bool\"} 或 {\"kind\":\"int\",\"lo\":0,\"hi\":3}")
		else:
			var auxs: Array = spec["aux"]
			aux_size = auxs.size()
			for k in aux_size:
				_validate_aux(auxs[k], "aux[%d]" % k, errors)

	# --- clue / globals 至少其一 ---
	var has_clue := spec.has("clue")
	var globals: Array = []
	if spec.has("globals"):
		if not (spec["globals"] is Array):
			errors.append("globals 必须是数组（IR 约束节点列表）")
		else:
			globals = spec["globals"]
	if not has_clue and globals.is_empty():
		errors.append("规格至少要定义 clue 或 globals 之一——否则该规则不产生任何约束")

	# --- clue ---
	if has_clue:
		_validate_clue(spec["clue"], geo, errors, warns)

	# --- globals ---
	for k in globals.size():
		_validate_global_node(globals[k], aux_size, "globals[%d]" % k, errors)

	# --- id 唯一性（跨注册表）：规格 id 必须全局唯一，否则会覆盖既有规则 ---
	# 注：措辞保持含「已被注册」四字——core/spec_helper.gd 的编辑期豁免按这个关键词识别
	#（"自己刚注册的那条"要放行，"别人的 id"要照实报错）。
	if id_ok and RuleRegistry.default().resolve(StringName(id)) != null:
		errors.append("id \"%s\" 已被注册（这个名字已经有别的规则在用了）——在 spec_ 后面改几个字母就行" % id)

	return {"ok": errors.is_empty(), "errors": errors, "warnings": _warn_texts(warns), "warning_codes": _warn_codes(warns)}


# ==================== clue 校验 ====================

static func _validate_clue(clue: Variant, geo: String, errors: PackedStringArray, warns: Array) -> void:
	if not (clue is Dictionary):
		errors.append("clue 必须是对象——形如 {\"refs\":[...],\"expr\":{...}}")
		return
	var c: Dictionary = clue

	# refs 两形态二选一：字符串 "topo"（拓扑邻接表）或固定偏移数组。
	var refs_v: Variant = c.get("refs")
	var refs_topo := false
	var refs_size := -1   # -1 = refs 未就绪 → expr 的 ref 越界检查跳过（只查节点类型）
	if refs_v is String:
		if refs_v != "topo":
			errors.append("clue.refs 字符串只允许 \"topo\"（收到 \"%s\"）——表示邻域 = 棋盘拓扑邻接表；固定偏移请写数组 [{\"dx\":int,\"dy\":int},...]" % str(refs_v))
		else:
			refs_topo = true
			if geo == "rect_only":
				errors.append("clue.refs=\"topo\" 与 geometry=\"rect_only\" 冲突——拓扑邻接表形态依赖邻接表，只在 adj_generic（非矩形盘）下有定义；请改 geometry=\"adj_generic\" 或改用固定偏移数组")
			# 合法规格但正向矩形求值无意义：不静默（否则用户不解为何 compute_clue 恒返回 empty_value）。
			var w := "clue.refs=\"topo\"：compute_clue（矩形正向求值）对该形态无意义（返回 empty_value），仅 compute_clue_topo（异形盘正向）有效——平台在异形盘改调该接口（core/puzzle_generator.gd:512-522）"
			warns.append({"code": "compute_clue_na", "text": w})
			push_warning("SpecSchema: " + w)
	elif not (refs_v is Array) or (refs_v as Array).is_empty():
		errors.append("clue.refs 必须是 \"topo\" 或非空数组 [{\"dx\":int,\"dy\":int},...]")
	else:
		var refs: Array = refs_v
		refs_size = refs.size()
		for k in refs_size:
			var r: Variant = refs[k]
			if not (r is Dictionary):
				errors.append("clue.refs[%d] 必须是对象 {\"dx\":int,\"dy\":int}（收到 %s）" % [k, str(r)])
				continue
			var rd: Dictionary = r
			if not _has_num(rd, "dx") or not _has_num(rd, "dy"):
				errors.append("clue.refs[%d] 的 dx/dy 必须是整数偏移（收到 dx=%s, dy=%s）" % [k, str(rd.get("dx")), str(rd.get("dy"))])
		# 几何自洽：固定偏移依赖矩形行列；异形盘上平台按拓扑邻域求值，固定偏移会得到错误线索值。
		if geo != "rect_only":
			errors.append("clue.refs 为固定偏移，但 geometry=\"%s\"——固定偏移依赖矩形行列，异形盘上平台按拓扑邻域求值（core/puzzle_generator.gd:494-505），固定偏移会得到错误线索值；请显式声明 geometry=\"rect_only\"，或改用 refs=\"topo\"" % geo)

	if not c.has("expr"):
		errors.append("clue.expr 缺失——线索值表达式必须写在 clue.expr（只允许 const/ref/sum/wsum）")
	else:
		_validate_clue_expr(c["expr"], refs_size, refs_topo, "clue.expr", errors)
		if refs_topo:
			# adj_generic（⇔ refs="topo"）在异形盘上的正向值由 compute_clue_topo 给出（本适配器
			# 按 expr 求值）⇒ 任意值域自洽；这里只做「不静默」的语义提醒，不阻断注册。
			_warn_topo_domain(c["expr"], warns)

	if c.has("max") and (not _is_num(c["max"]) or int(c["max"]) < 0):
		errors.append("clue.max 必须是非负整数（收到 %s）——缺省为 refs 数量" % str(c["max"]))
	if c.has("empty_value") and not _is_num(c["empty_value"]):
		errors.append("clue.empty_value 必须是整数（收到 %s）" % str(c["empty_value"]))


static func _validate_clue_expr(e: Variant, refs_size: int, refs_topo: bool, path: String, errors: PackedStringArray) -> void:
	if not (e is Dictionary):
		errors.append("%s 必须是 IR 节点对象（收到 %s）" % [path, str(e)])
		return
	var d: Dictionary = e
	var t := str(d.get("t", ""))
	if not CLUE_EXPR_TYPES.has(t):
		errors.append("%s 不允许节点类型 \"%s\"——线索值必须可无 aux 求值，只允许 const/ref/sum/wsum" % [path, t])
		return
	match t:
		"const":
			if not _is_num(d.get("v")):
				errors.append("%s 的 const.v 必须是整数（收到 %s）" % [path, str(d.get("v"))])
		"ref":
			var i: Variant = d.get("i")
			if not _is_num(i):
				errors.append("%s 的 ref.i 必须是整数索引（收到 %s）" % [path, str(i)])
			elif int(i) < 0:
				errors.append("%s 的 ref.i 不能为负（收到 %d）" % [path, int(i)])
			elif refs_topo:
				if int(i) >= TOPO_REF_MAX:
					errors.append("%s 的 ref 索引 %d 过大——topo 形态按运行时邻接表下标取值（度数上限保守设为 %d）" % [path, int(i), TOPO_REF_MAX])
			elif refs_size >= 0 and int(i) >= refs_size:
				errors.append("%s 的 ref 索引 %d 越界——refs 只有 %d 项（索引区间 0..%d）" % [path, int(i), refs_size, refs_size - 1])
		"sum":
			var xs: Variant = d.get("xs")
			if not (xs is Array) or (xs as Array).is_empty():
				errors.append("%s 的 sum.xs 必须是非空数组" % path)
			else:
				var xs_a: Array = xs
				for k in xs_a.size():
					_validate_clue_expr(xs_a[k], refs_size, refs_topo, "%s.xs[%d]" % [path, k], errors)
		"wsum":
			var ws: Variant = d.get("ws")
			var xs2: Variant = d.get("xs")
			if not (ws is Array) or not (xs2 is Array) or (ws as Array).size() != (xs2 as Array).size():
				errors.append("%s 的 wsum 要求 ws 与 xs 都是数组且等长（收到 ws=%s, xs=%s）" % [path, str(ws), str(xs2)])
				return
			var ws_a: Array = ws
			var xs_a2: Array = xs2
			if ws_a.is_empty():
				errors.append("%s 的 wsum.ws 不能为空" % path)
				return
			for k in ws_a.size():
				if not _is_num(ws_a[k]):
					errors.append("%s 的 wsum.ws[%d] 必须是整数权重（收到 %s）" % [path, k, str(ws_a[k])])
				_validate_clue_wsum_item(xs_a2[k], refs_size, refs_topo, "%s.xs[%d]" % [path, k], errors)


## wsum 的 xs 项只允许 ref|const（与 core/rule_builder.gd 的 wsum/lin 同契约）。
static func _validate_clue_wsum_item(x: Variant, refs_size: int, refs_topo: bool, path: String, errors: PackedStringArray) -> void:
	if not (x is Dictionary):
		errors.append("%s 必须是 ref|const（收到 %s）—— 线索值不允许含非引用项" % [path, str(x)])
		return
	var t := str((x as Dictionary).get("t", ""))
	if t != "ref" and t != "const":
		errors.append("%s 必须是 ref|const（收到 %s）—— 线索值不允许含 %s" % [path, t, t])
		return
	_validate_clue_expr(x, refs_size, refs_topo, path, errors)


## refs="topo" 的两条不阻断告警（与值域形态无关；值由 compute_clue_topo 给出 ⇒ 任意值域自洽）。
## 1) ref i 的绑定序 = **适配器固定的 (y,x) 升序**（非邻接表插入序）—— 见下方 text；
## 2) 未被引用的邻居在正向与约束两侧都被忽略（自洽，但窗口可能小于作者以为的度数）；
## 【2026-10-01 主代理】原第 3 条 `e2e_gap`（"加载/显示与验收 round-trip 未接 compute_clue_topo"）
## **已删除**：该缺口已修（`core/board.gd:_compute_clues` 与 `tools/verify_batch.gd` 现优先问规则的
## 拓扑求值），并转成真断言 `test/unit/test_spec_end_to_end.gd::test_board_load_side_uses_rule_topo_clue_values`。
## 保留 `ref_order` 这个 code（tools/spec_check.gd 按 code 判级遇到未知 code 会退回文案判据）。
static func _warn_topo_domain(e: Variant, warns: Array) -> void:
	warns.append({"code": "ref_order", "text": "clue.refs=\"topo\" 的 ref i = 本格邻居按 **(y,x) 升序**排序后的第 i 个（适配器内部固定序 `SpecRulePlugin._sorted_neighbors`）：**与邻接表的物理存储/插入序无关** ⇒ 生成期与载入期含义一致（原先绑插入序会在落盘/载入往返后漂移，属静默不可解缺陷，2026-10-01 已修）。注意 k 的语义由「邻居个数」给出，不同格的度数可能不同（蜂窝 3/4/6 度混排），超出度数的 ref 按 0 计。"})
	var k := _max_ref_index(e) + 1
	if k > 0:
		warns.append({"code": "coverage", "text": "clue.refs=\"topo\" 只引用邻接表前 %d 个邻居（最大 ref 索引 %d）：未被引用的邻居在正向与约束两侧都被忽略（自洽，但窗口可能小于实际度数）——请确认已覆盖所需邻居" % [k, k - 1]})


## expr 中出现的最大 ref 索引（无 ref ⇒ -1）。用于提醒「拓扑窗口覆盖度」。
static func _max_ref_index(e: Variant) -> int:
	if not (e is Dictionary):
		return -1
	var d: Dictionary = e
	match str(d.get("t", "")):
		"ref":
			return int(d["i"]) if _is_num(d.get("i")) else -1
		"sum", "wsum":
			var m := -1
			var xs: Variant = d.get("xs")
			if xs is Array:
				for x in (xs as Array):
					m = maxi(m, _max_ref_index(x))
			return m
	return -1


# ==================== globals 校验 ====================

static func _validate_global_node(n: Variant, aux_size: int, path: String, errors: PackedStringArray) -> void:
	if not (n is Dictionary):
		errors.append("%s 必须是 IR 节点对象（收到 %s）" % [path, str(n)])
		return
	var d: Dictionary = n
	var t := str(d.get("t", ""))
	if t == "ref":
		errors.append("%s 出现 ref 节点——ref 是 clue.expr 专用的相对偏移；globals 请改用 cell 绝对坐标" % path)
		return
	if not GLOBAL_NODE_TYPES.has(t):
		errors.append("%s 的节点类型 \"%s\" 不支持——允许 %s" % [path, t, str(GLOBAL_NODE_TYPES)])
		return
	match t:
		"cell":
			if not _has_num(d, "r") or not _has_num(d, "c"):
				errors.append("%s 的 cell 需要整数 r/c（收到 r=%s, c=%s）" % [path, str(d.get("r")), str(d.get("c"))])
			elif int(d["r"]) < 0 or int(d["c"]) < 0:
				errors.append("%s 的 cell 坐标 (%d,%d) 为负——坐标必须非负（盘内检查在建盘时按实际尺寸再报）" % [path, int(d["r"]), int(d["c"])])
		"aux":
			var i: Variant = d.get("i")
			if not _is_num(i):
				errors.append("%s 的 aux.i 必须是整数索引（收到 %s）" % [path, str(i)])
			elif int(i) < 0 or int(i) >= aux_size:
				errors.append("%s 的 aux 索引 %d 越界——aux 只声明了 %d 项（索引区间 0..%d）" % [path, int(i), aux_size, aux_size - 1])
		"const":
			if not _is_num(d.get("v")):
				errors.append("%s 的 const.v 必须是整数（收到 %s）" % [path, str(d.get("v"))])
		"sum", "all_diff":
			_validate_global_list(d.get("xs"), aux_size, path + ".xs", errors)
		"wsum", "lin":
			_validate_global_affine(d, aux_size, path, errors)
		"not":
			_validate_global_node(d.get("x"), aux_size, path + ".x", errors)
		"eq", "le", "lt", "imp", "iff":
			_validate_global_node(d.get("a"), aux_size, path + ".a", errors)
			_validate_global_node(d.get("b"), aux_size, path + ".b", errors)
		"bool_or", "bool_and":
			_validate_global_lits(d.get("lits"), aux_size, path + ".lits", errors)
		"enforce":
			_validate_global_lits(d.get("lits"), aux_size, path + ".lits", errors)
			_validate_global_node(d.get("c"), aux_size, path + ".c", errors)


static func _validate_global_list(xs: Variant, aux_size: int, path: String, errors: PackedStringArray) -> void:
	if not (xs is Array) or (xs as Array).is_empty():
		errors.append("%s 必须是数组（元素为 IR 表达式节点）" % path)
		return
	var xs_a: Array = xs
	for k in xs_a.size():
		_validate_global_node(xs_a[k], aux_size, "%s[%d]" % [path, k], errors)


static func _validate_global_lits(lits: Variant, aux_size: int, path: String, errors: PackedStringArray) -> void:
	if not (lits is Array):
		errors.append("%s 必须是字面量数组（变量引用，或 not 包裹）" % path)
		return
	var lits_a: Array = lits
	for k in lits_a.size():
		_validate_global_node(lits_a[k], aux_size, "%s[%d]" % [path, k], errors)


## wsum/lin：ws 与 xs 等长且为整数权重；xs 项只能是 cell|aux|const（CPIR 契约）。
static func _validate_global_affine(d: Dictionary, aux_size: int, path: String, errors: PackedStringArray) -> void:
	var ws: Variant = d.get("ws")
	var xs: Variant = d.get("xs")
	if not (ws is Array) or not (xs is Array) or (ws as Array).size() != (xs as Array).size():
		errors.append("%s 要求 ws 与 xs 都是数组且等长（收到 ws=%s, xs=%s）" % [path, str(ws), str(xs)])
		return
	var ws_a: Array = ws
	var xs_a: Array = xs
	if ws_a.is_empty():
		errors.append("%s 的 ws 不能为空" % path)
		return
	for k in ws_a.size():
		if not _is_num(ws_a[k]):
			errors.append("%s 的 ws[%d] 必须是整数权重（收到 %s）" % [path, k, str(ws_a[k])])
		var x: Variant = xs_a[k]
		if not (x is Dictionary) or not ["cell", "aux", "const"].has(str((x as Dictionary).get("t", ""))):
			errors.append("%s 的 xs[%d] 必须是 cell|aux|const（收到 %s）—— wsum/lin 的项只能是变量引用或常量" % [path, k, str(x)])
			continue
		_validate_global_node(x, aux_size, "%s.xs[%d]" % [path, k], errors)
	if d.has("c") and not _is_num(d["c"]):
		errors.append("%s 的 c 必须是整数常量项（收到 %s）" % [path, str(d["c"])])


# ==================== aux 校验 ====================

static func _validate_aux(a: Variant, path: String, errors: PackedStringArray) -> void:
	if not (a is Dictionary):
		errors.append("%s 必须是对象 {\"kind\":\"bool\"} 或 {\"kind\":\"int\",\"lo\":0,\"hi\":3}（收到 %s）" % [path, str(a)])
		return
	var d: Dictionary = a
	var kind := str(d.get("kind", ""))
	match kind:
		"bool":
			pass
		"int":
			if not _has_num(d, "lo") or not _has_num(d, "hi"):
				errors.append("%s 的 int aux 需要整数 lo/hi（收到 lo=%s, hi=%s）" % [path, str(d.get("lo")), str(d.get("hi"))])
			elif int(d["lo"]) > int(d["hi"]):
				errors.append("%s 的 int aux 域非法：lo(%d) > hi(%d)" % [path, int(d["lo"]), int(d["hi"])])
		_:
			errors.append("%s 的 kind \"%s\" 不支持——只允许 \"bool\" 或 \"int\"" % [path, kind])


# ==================== 小工具 ====================

## 从结构化告警派生 warnings 文本数组（与 warning_codes 严格同序同长）。
static func _warn_texts(warns: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for w in warns:
		out.append(str((w as Dictionary).get("text", "")))
	return out


## 派生 warning_codes（稳定判级键）。约定：ref_order = 邻居序语义（已固定为 (y,x) 升序）；
## coverage = 拓扑窗口覆盖度；compute_clue_na = 矩形正向无意义。
## 【2026-10-01】e2e_gap 已退役（加载/验收侧接线完成）——不再产生该 code。
## 消费方应对**未知 code 保持 INFO**，以便本文件新增 code 时不被静默升级。
static func _warn_codes(warns: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for w in warns:
		out.append(str((w as Dictionary).get("code", "")))
	return out


## JSON 数字在 Godot 里统一解析为 float，故「整数」判定须同时接受 int/float（bool 不算）。
static func _is_num(v: Variant) -> bool:
	return v is int or v is float


static func _has_num(d: Dictionary, key: String) -> bool:
	return d.has(key) and _is_num(d[key])
