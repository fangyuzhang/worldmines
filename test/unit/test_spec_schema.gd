# test_spec_schema.gd —— 声明式变体规格（spec v1）适配器的自证
# 覆盖：
#   1) SpecSchema.validate 的合法/非法用例（错误信息必须含可行动关键词）；
#   2) 等价性铁证：n8+sum 规格 vs 内置 ClassicRule（逐值 + IR 结构 + 边界语义）；
#   3) 几何自洽：refs 两形态（固定偏移 ⇔ rect_only；"topo" ⇔ adj_generic）的校验与警告；
#   4) 拓扑正向：纯邻域和规格的 compute_clue_topo == 旧硬编码计数（蜂窝盘逐格）；
#      加权值域规格的正向/逆向同源一致（证明「值算一套、约束另一套」已消除）；
#   5) 端到端（仅生成侧）：refs="topo" 规格能在蜂窝盘产出非空关卡；
#      加载/显示与验收 round-trip 未接 compute_clue_topo 的缺口另记 pending（见文件末尾）；
#   6) from_json / register_from_json（成功留痕 / 失败不留痕）；globals 的 aux 按序对齐。
extends GutTest


# ==================== 通用工具 ====================

func _uid(tag: String) -> String:
	# 注册表是进程级单例，测试重复执行时 id 必须不撞，故带随机后缀。
	return "spec_test_%s_%d" % [tag, randi()]


# 【2026-10-01 主代理复审加固】注册表是**进程级单例**（core/rule_registry.gd:32-39，且**没有 clear()**）：
# 本文件原先注册完不清理 ⇒ 规则永久留在全局表（GUT 单进程跑 138 个脚本，表随运行膨胀），
# 且一旦 `_uid()` 的随机后缀被「确定化」（为了可复现很容易这么改）就**立刻**变成测试顺序依赖
#（后一个用例注册同 id 会失败，而失败原因与用例本身无关）。这里显式记录并在每个用例后注销。
# 安全性：`unregister` 拒绝注销内置 id（rule_registry.gd:62-66），而这里全是 spec_test_* 外部 id。
var _registered_ids: Array[String] = []


func after_each() -> void:
	for rid in _registered_ids:
		RuleRegistry.default().unregister(StringName(rid))
	_registered_ids.clear()


func _has_kw(errors, kw: String) -> bool:
	for e in errors:
		if str(e).find(kw) != -1:
			return true
	return false


## 最小合法规格（clue 恒为 0；固定偏移 ⇒ 必须 rect_only）。
func _base_spec(id: String) -> Dictionary:
	return {
		"spec_version": 1,
		"id": id,
		"title": "基线规格",
		"geometry": "rect_only",
		"clue": {
			"refs": [{"dx": 0, "dy": 0}],
			"expr": {"t": "const", "v": 0},
		},
	}


## 复刻内置 classic：refs 顺序 == ClueEngine.ring_dirs()，expr = Σ ref。
## 固定偏移依赖矩形行列 ⇒ geometry 必须显式 rect_only（几何自洽约束）。
func _classic_spec(id: String) -> Dictionary:
	var refs: Array = []
	for d in ClueEngine.ring_dirs():
		refs.append({"dx": d.x, "dy": d.y})
	var xs: Array = []
	for i in refs.size():
		xs.append({"t": "ref", "i": i})
	return {
		"spec_version": 1,
		"id": id,
		"title": "测试用经典8邻",
		"geometry": "rect_only",
		"clue": {"refs": refs, "expr": {"t": "sum", "xs": xs}},
	}


## 拓扑邻域规格：refs="topo"，expr = Σ ref 0..ref_count-1（越界 ref 运行时为 0）。
func _topo_spec(id: String, ref_count: int = 8) -> Dictionary:
	var xs: Array = []
	for i in ref_count:
		xs.append({"t": "ref", "i": i})
	return {
		"spec_version": 1,
		"id": id,
		"title": "测试用拓扑邻域规格",
		"geometry": "adj_generic",
		"clue": {"refs": "topo", "expr": {"t": "sum", "xs": xs}},
	}


func _assert_invalid(spec: Dictionary, kw: String) -> void:
	var v := SpecSchema.validate(spec)
	assert_false(bool(v["ok"]), "应判为非法（关键词 %s）" % kw)
	assert_true(_has_kw(v["errors"], kw), "错误信息应含 \"%s\"，实际：%s" % [kw, str(v["errors"])])


func _random_mine_set(rng: RandomNumberGenerator, gsize: Vector2i, density: float) -> Dictionary:
	var ms := {}
	for r in gsize.y:
		for c in gsize.x:
			if rng.randf() < density:
				ms[Vector2i(c, r)] = true
	return ms


# ==================== 1. 校验器 ====================

func test_valid_spec_passes() -> void:
	var v := SpecSchema.validate(_base_spec(_uid("ok")))
	assert_true(bool(v["ok"]), "合法规格应通过：%s" % str(v["errors"]))
	assert_eq(v["errors"].size(), 0, "通过时不应有错误")
	assert_eq(v["warning_codes"].size(), v["warnings"].size(), "warning_codes 必须与 warnings 同序同长")


func test_invalid_missing_title() -> void:
	var spec := _base_spec(_uid("notitle"))
	spec.erase("title")
	_assert_invalid(spec, "title")


func test_invalid_bad_atom() -> void:
	var spec := _base_spec(_uid("badatom"))
	spec["clue"]["expr"] = {"t": "frobnicate"}
	_assert_invalid(spec, "frobnicate")


func test_invalid_aux_in_clue_expr() -> void:
	var spec := _base_spec(_uid("auxexpr"))
	spec["clue"]["expr"] = {"t": "aux", "i": 0}
	_assert_invalid(spec, "aux")


func test_invalid_aux_in_wsum_item() -> void:
	var spec := _base_spec(_uid("wsumaux"))
	spec["clue"]["expr"] = {
		"t": "wsum", "ws": [1, 1],
		"xs": [{"t": "ref", "i": 0}, {"t": "aux", "i": 0}],
	}
	_assert_invalid(spec, "ref|const")


func test_invalid_ref_index_out_of_range() -> void:
	var spec := _base_spec(_uid("refoor"))
	spec["clue"]["expr"] = {"t": "ref", "i": 5}
	_assert_invalid(spec, "越界")


func test_invalid_globals_ref() -> void:
	var spec := _base_spec(_uid("gref"))
	spec["globals"] = [
		{"t": "le", "a": {"t": "ref", "i": 0}, "b": {"t": "const", "v": 1}},
	]
	_assert_invalid(spec, "ref")


func test_invalid_globals_negative_cell() -> void:
	var spec := _base_spec(_uid("gneg"))
	spec["globals"] = [
		{"t": "le", "a": {"t": "cell", "r": -1, "c": 0}, "b": {"t": "const", "v": 1}},
	]
	_assert_invalid(spec, "负")


func test_invalid_globals_aux_out_of_range() -> void:
	var spec := _base_spec(_uid("gauxoor"))
	spec["globals"] = [
		{"t": "le", "a": {"t": "aux", "i": 3}, "b": {"t": "const", "v": 1}},
	]
	_assert_invalid(spec, "aux 索引")


func test_invalid_id_without_prefix() -> void:
	var spec := _base_spec("classic_like")
	_assert_invalid(spec, "spec_")


func test_invalid_hidden_state() -> void:
	var spec := _base_spec(_uid("hidden"))
	spec["hidden_state"] = {"k": 1}
	_assert_invalid(spec, "隐藏态")


func test_invalid_spec_version() -> void:
	var spec := _base_spec(_uid("ver"))
	spec["spec_version"] = 2
	_assert_invalid(spec, "spec_version")


func test_invalid_duplicate_id() -> void:
	var id := _uid("dup")
	var spec := _classic_spec(id)
	var r := SpecRulePlugin.register_from_json(JSON.stringify(spec))
	assert_true(bool(r["ok"]), "首次注册应成功：%s" % str(r["errors"]))
	_registered_ids.append(id)   # 复审加固：after_each 负责注销，不留全局残留
	# 同一 id 再次校验 → 重复报错。关键词在 2026-10-02 改成了「已被注册」：
	# 原文"必须全局唯一"是写给作者看的，小白读不懂；新文案仍带"已被注册"（编辑期豁免按它识别），
	# 并直接告诉他怎么改。断言的**意图不变**：这条错误必须说明"名字被占了"。
	_assert_invalid(spec, "已被注册")


# ==================== 2. 几何自洽（refs 两形态 ⇔ geometry）====================

func test_invalid_offset_refs_with_adj_generic() -> void:
	# 固定偏移 + adj_generic：异形盘会按拓扑邻域求值，固定偏移得到错误线索值 ⇒ 必须报错。
	var spec := _base_spec(_uid("adjoff"))
	spec["geometry"] = "adj_generic"
	_assert_invalid(spec, "rect_only")


func test_invalid_topo_refs_with_rect_only() -> void:
	var spec := _topo_spec(_uid("toporect"))
	spec["geometry"] = "rect_only"
	_assert_invalid(spec, "冲突")


func test_invalid_offset_refs_without_geometry() -> void:
	# 缺省 geometry = adj_generic ⇒ 固定偏移同样不合法。
	var spec := _base_spec(_uid("nogeo"))
	spec.erase("geometry")
	_assert_invalid(spec, "rect_only")


func test_invalid_topo_ref_index_too_large() -> void:
	var spec := _topo_spec(_uid("topobig"), 1)
	spec["clue"]["expr"] = {"t": "ref", "i": 999}
	_assert_invalid(spec, "过大")


func test_topo_weighted_expr_passes_with_warning() -> void:
	# 平台现在按 compute_clue_topo 取正向值（本插件覆写为按 expr 求值）⇒ 加权值域自洽，不再报错。
	var spec := _topo_spec(_uid("topowsum"))
	spec["clue"]["expr"] = {"t": "wsum", "ws": [2, 2], "xs": [{"t": "ref", "i": 0}, {"t": "ref", "i": 1}]}
	var v := SpecSchema.validate(spec)
	assert_true(bool(v["ok"]), "加权 topo 值域应合法（正向/逆向同源）：%s" % str(v["errors"]))
	assert_true(_has_kw(v["warnings"], "邻居"), "应给出拓扑覆盖度提醒（不静默）：%s" % str(v["warnings"]))


func test_topo_weighted_value_consistent_between_forward_and_reverse() -> void:
	# 自证「值算一套、约束另一套」已消除：正向 compute_clue_topo 与逆向约束读同一 expr。
	var topo: GridInterface = _hex_topo()
	if topo == null:
		return
	var spec := _topo_spec(_uid("topowval"))
	spec["clue"]["expr"] = {"t": "wsum", "ws": [2, 2], "xs": [{"t": "ref", "i": 0}, {"t": "ref", "i": 1}]}
	var res := SpecRulePlugin.from_json(JSON.stringify(spec))
	assert_true(bool(res["ok"]), str(res["errors"]))
	var rule = res["rule"]

	# 找一块度 ≥2 的格，把「ref0/ref1 对应的邻居」置雷 ⇒ 正向值应为 2+2=4（而非邻域计数 2）。
	# 【主代理 2026-10-01 修】ref i 的绑定序**不是**邻接表插入序，而是适配器定义的确定性序
	# （`SpecRulePlugin._sorted_neighbors`：按 (y,x) 升序；理由见该函数注释——插入序在
	#  落盘/载入往返后会漂，会让 ref i 指向别的邻居 ⇒ 静默不可解）。测试必须按同一个序摆雷。
	var ms := {}
	var target := Vector2i.ZERO
	var found := false
	for pos in topo.all_positions():
		var nbs: Array = SpecRulePlugin._sorted_neighbors(topo.get_neighbors(pos))
		if nbs.size() >= 2:
			ms[nbs[0]] = true
			ms[nbs[1]] = true
			target = pos
			found = true
			break
	assert_true(found, "蜂窝盘应存在度 ≥2 的格")
	assert_eq(int(rule.compute_clue_topo(ms, target, topo, topo.size())), 4,
		"正向值必须按 expr（2*ref0 + 2*ref1）给出，而非邻域计数 2")

	var asg := {}
	for p in ms:
		asg[CPIR.cell_key(p.y, p.x)] = 1
	var b := RuleBuilder.new(topo.size().y, topo.size().x)
	b.set_topology(topo)
	rule.build_clue_constraints(b, target, 4)
	assert_true(CPIR.eval_all(b.constraints, asg), "逆向约束应在 value=4 且前两邻居为雷时成立")
	var b2 := RuleBuilder.new(topo.size().y, topo.size().x)
	b2.set_topology(topo)
	rule.build_clue_constraints(b2, target, 2)
	assert_false(CPIR.eval_all(b2.constraints, asg), "value=2 时约束应不成立（证明约束按 expr 而非邻域计数）")


func test_valid_topo_all_ones_wsum_passes() -> void:
	var ws: Array = []
	var xs: Array = []
	for i in 6:
		ws.append(1)
		xs.append({"t": "ref", "i": i})
	var spec := _topo_spec(_uid("topow1"))
	spec["clue"]["expr"] = {"t": "wsum", "ws": ws, "xs": xs}
	var v := SpecSchema.validate(spec)
	assert_true(bool(v["ok"]), "全 1 权重的 wsum 等价于纯邻域和，应通过：%s" % str(v["errors"]))


func test_topo_refs_spec_passes_with_warning() -> void:
	var res := SpecRulePlugin.from_json(JSON.stringify(_topo_spec(_uid("topowarn"))))
	assert_true(bool(res["ok"]), "topo 形态应通过校验：%s" % str(res["errors"]))
	assert_true(res["warnings"].size() > 0, "topo 形态必须在校验阶段给出警告（不静默）")
	assert_true(_has_kw(res["warnings"], "topo"), "警告应说明 topo 形态")
	assert_true(_has_kw(res["warnings"], "邻接表"), "应提醒 ref 绑定邻接表插入序（非跨实例稳定契约）")
	assert_true(_has_kw(res["warnings"], "邻居"), "应提醒拓扑窗口覆盖度（未引用的邻居被两侧忽略）")
	# warning_codes 必须与 warnings 同序同长（tools/spec_check.gd 按下标配对判级）
	var codes: PackedStringArray = res["warning_codes"]
	assert_eq(codes.size(), res["warnings"].size(), "warning_codes 必须与 warnings 同长")
	assert_true(_has_kw(codes, "ref_order"), "邻居序语义应有 code=ref_order")
	assert_true(_has_kw(codes, "coverage"), "拓扑覆盖度应有 code=coverage")
	# 【主代理 2026-10-01】原 `e2e_gap` 断言已删：该 code 随缺口修复一起退役（加载/验收侧已接
	# compute_clue_topo）。这里反向钉住"不得复活"——若有人把已修的缺口又写回告警，本断言会红。
	assert_false(_has_kw(codes, "e2e_gap"), "e2e_gap 已退役（缺口已修），不得再作为告警出现")
	assert_false(_has_kw(res["warnings"], "端到端"),
		"告警文案不应再声称「端到端不可用」——那与已修复的事实矛盾")


func test_geometry_kind_follows_refs_form() -> void:
	var res := SpecRulePlugin.from_json(JSON.stringify(_base_spec(_uid("geo"))))
	assert_true(bool(res["ok"]), str(res["errors"]))
	assert_eq(res["rule"].geometry_kind(), RulePlugin.GEO_RECT_ONLY, "固定偏移形态应为 rect_only(1)")
	var res2 := SpecRulePlugin.from_json(JSON.stringify(_topo_spec(_uid("geo2"))))
	assert_true(bool(res2["ok"]), str(res2["errors"]))
	assert_eq(res2["rule"].geometry_kind(), RulePlugin.GEO_ADJ_GENERIC, "topo 形态应为 adj_generic(0)")
	assert_true(res2["rule"].supports_topology(), "topo 形态必须声明支持拓扑（否则被生成器回退 classic）")


# ==================== 3. 等价性铁证（矩形）====================

func test_equivalence_compute_clue_with_classic() -> void:
	var spec := _classic_spec(_uid("clsc"))
	var res := SpecRulePlugin.from_json(JSON.stringify(spec))
	assert_true(bool(res["ok"]), "n8+sum 规格应通过校验：%s" % str(res["errors"]))
	var rule = res["rule"]
	var classic = RuleRegistry.default().resolve(&"classic")
	assert_not_null(classic, "内置 classic 必须已注册")

	var rng := RandomNumberGenerator.new()
	rng.seed = 20261001
	var gsize := Vector2i(5, 5)
	var mismatch := 0
	for _t in 25:
		var ms := _random_mine_set(rng, gsize, 0.3)
		for r in gsize.y:
			for c in gsize.x:
				var pos := Vector2i(c, r)
				var a := int(rule.compute_clue(ms, pos, gsize))
				var b := int(classic.compute_clue(ms, pos, gsize))
				if a != b:
					mismatch += 1
	assert_eq(mismatch, 0, "spec 与 ClassicRule 的 compute_clue 必须逐值一致（含边界格）")

	# mine_set 也要接受 Array[Vector2i]（pos=(2,2)，仅 (1,1) 落进邻域）
	var arr_ms: Array[Vector2i] = [Vector2i(1, 1), Vector2i(2, 2)]
	assert_eq(int(rule.compute_clue(arr_ms, Vector2i(2, 2), gsize)), 1, "Array 雷集：自身不计入邻域")


func test_equivalence_build_clue_ir_with_classic() -> void:
	var spec := _classic_spec(_uid("clir"))
	var res := SpecRulePlugin.from_json(JSON.stringify(spec))
	assert_true(bool(res["ok"]), str(res["errors"]))
	var rule = res["rule"]
	var classic = RuleRegistry.default().resolve(&"classic")

	var gsize := Vector2i(5, 5)
	# (a) 内部格：refs 顺序与 ring_dirs 一致 ⇒ IR 逐字节相同
	var b_spec := RuleBuilder.new(gsize.y, gsize.x)
	rule.build_clue_constraints(b_spec, Vector2i(2, 2), 3)
	var b_cls := RuleBuilder.new(gsize.y, gsize.x)
	classic.build_clue_constraints(b_cls, Vector2i(2, 2), 3)
	assert_eq(JSON.stringify(b_spec.constraints), JSON.stringify(b_cls.constraints),
		"内部格上 spec 的 IR 应与 ClassicRule 结构等价（逐字节）")

	# (b) 边界格：spec 用 const 0 填出界项，classic 过滤出界项 → 结构不同但语义必须等价。
	var b2 := RuleBuilder.new(gsize.y, gsize.x)
	rule.build_clue_constraints(b2, Vector2i(0, 0), 2)
	var c2 := RuleBuilder.new(gsize.y, gsize.x)
	classic.build_clue_constraints(c2, Vector2i(0, 0), 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var same := 0
	for _t in 200:
		var asg := {}
		for r in gsize.y:
			for c in gsize.x:
				asg[CPIR.cell_key(r, c)] = rng.randi_range(0, 1)
		if CPIR.eval_all(b2.constraints, asg) == CPIR.eval_all(c2.constraints, asg):
			same += 1
	assert_eq(same, 200, "边界格：spec(含 const 0 填充) 与 classic(过滤出界) 的约束语义应逐赋值等价")


# ==================== 4. 拓扑正向（蜂窝盘）====================

func _hex_topo() -> GridInterface:
	var raw = ShapeGenerator.to_adjacency_grid("hex", {"size": 7})
	assert_not_null(raw, "蜂窝盘构造失败（ShapeGenerator 契约变化？）")
	if raw == null:
		return null
	# 归一化到非负坐标（与 tools/gen_geo_levels.gd:312 同口径），保证 CP-SAT cell 索引合法。
	return AdjacencyGrid.normalized(raw)


func _first_k_mines(topo: GridInterface, k: int) -> Dictionary:
	var ms := {}
	var n := 0
	for p in topo.all_positions():
		if n >= k:
			break
		ms[p] = true
		n += 1
	return ms


func test_topo_compute_clue_topo_equals_legacy_count() -> void:
	var topo: GridInterface = _hex_topo()
	if topo == null:
		return
	var res := SpecRulePlugin.from_json(JSON.stringify(_topo_spec(_uid("topoeq"))))
	assert_true(bool(res["ok"]), str(res["errors"]))
	var rule = res["rule"]
	# topo 形态下 compute_clue（矩形）无意义 ⇒ empty_value（0）；仅 compute_clue_topo 有效。
	assert_eq(int(rule.compute_clue({}, Vector2i(0, 0), topo.size())), 0,
		"topo 形态的 compute_clue 应为 empty_value（矩形正向无意义）")

	var ms := _first_k_mines(topo, 8)
	var mismatch := 0
	for pos in topo.all_positions():
		var legacy: int = int(PuzzleGenerator._count_topo_mines(ms, topo.get_neighbors(pos)))
		var v: int = int(rule.compute_clue_topo(ms, pos, topo, topo.size()))
		if v != legacy:
			mismatch += 1
	assert_eq(mismatch, 0, "topo 形态的 compute_clue_topo 必须等于平台旧硬编码拓扑邻域计数")


func test_topo_refs_generates_nonempty_hex_level() -> void:
	var topo: GridInterface = _hex_topo()
	if topo == null:
		return
	var sid := _uid("topogen")
	var reg := SpecRulePlugin.register_from_json(JSON.stringify(_topo_spec(sid)))
	assert_true(bool(reg["ok"]), "topo 规格注册应成功：%s" % str(reg["errors"]))
	_registered_ids.append(sid)   # 复审加固：after_each 负责注销
	var gen := PuzzleGenerator.new()
	var level: Dictionary = gen.generate_with_rules(
		String(reg["id"]), [], topo.size(), 12, 1, 0, 15, topo, 30_000)
	assert_false(level.is_empty(),
		"refs=\"topo\" 规格应能在蜂窝盘产出非空关卡；last_call_stats=%s" % str(gen.last_call_stats))


# ==================== 5. from_json / register_from_json ====================

func test_from_json_bad_text() -> void:
	## 【主代理修：测试卫生】原先喂**畸形 JSON**（`"{ 不是合法 JSON "`）——那会让引擎打印
	## `ERROR: Parse JSON failed ...`，GUT 把引擎 ERROR 记为 "Unexpected Errors" ⇒ 全套变红
	## （而生产行为其实是正确的：返回 ok=false）。畸形输入的路径改由 CLI 级验收覆盖
	##（`tools/spec_check.gd --spec=<坏文件>`），GUT 里只断言"合法 JSON 但不是对象"这一类，
	## 它走的是同一条 `parsed is Dictionary` 分支且不产生引擎错误。
	for bad in ["[]", "123", "\"just a string\"", "null"]:
		var res := SpecRulePlugin.from_json(bad)
		assert_false(bool(res["ok"]), "合法 JSON 但非对象（%s）必须被拒" % bad)
		assert_true(_has_kw(res["errors"], "对象"),
			"应提示「顶层必须是 JSON 对象」（%s → %s）" % [bad, str(res["errors"])])


func test_register_from_json_no_trace_on_failure() -> void:
	var id := _uid("reg")
	var r1 := SpecRulePlugin.register_from_json(JSON.stringify(_classic_spec(id)))
	assert_true(bool(r1["ok"]), "首次注册应成功：%s" % str(r1["errors"]))
	_registered_ids.append(id)   # 复审加固：after_each 负责注销
	assert_eq(String(r1["id"]), id)
	assert_not_null(RuleRegistry.default().resolve(StringName(id)), "注册后应可解析")

	# 用另一个规格抢占同一 id：必须失败，且既有规则不得被覆盖/移除。
	var hijack := _base_spec(id)
	hijack["title"] = "篡改标题"
	var r2 := SpecRulePlugin.register_from_json(JSON.stringify(hijack))
	assert_false(bool(r2["ok"]), "重复 id 必须注册失败")
	assert_eq(String(r2["id"]), "", "失败时 id 应为空")
	var existing = RuleRegistry.default().resolve(StringName(id))
	assert_not_null(existing, "既有规则不得被移除")
	assert_eq(str(existing.describe()["name"]), "测试用经典8邻", "既有规则不得被覆盖（失败不留痕）")


# ==================== 6. globals / aux ====================

func test_global_aux_creation_alignment() -> void:
	var spec := {
		"spec_version": 1,
		"id": _uid("aux"),
		"title": "测试全局 aux",
		"globals": [
			{"t": "eq",
				"a": {"t": "sum", "xs": [{"t": "aux", "i": 0}, {"t": "aux", "i": 1}]},
				"b": {"t": "const", "v": 1}},
		],
		"aux": [{"kind": "bool"}, {"kind": "int", "lo": 0, "hi": 3}],
	}
	var res := SpecRulePlugin.from_json(JSON.stringify(spec))
	assert_true(bool(res["ok"]), str(res["errors"]))
	var rule = res["rule"]

	var b := RuleBuilder.new(3, 3)
	rule.build_global_constraints(b)
	assert_eq(b.aux_vars.size(), 2, "应按 spec 声明创建 2 个 aux")
	assert_eq(int(b.aux_vars[0]["i"]), 0, "bool aux 索引应为 0")
	assert_eq(str(b.aux_vars[0]["kind"]), "bool")
	assert_eq(int(b.aux_vars[1]["i"]), 1, "int aux 索引应为 1")
	assert_eq(str(b.aux_vars[1]["kind"]), "int")
	assert_eq(int(b.aux_vars[1]["lo"]), 0, "int aux 下界")
	assert_eq(int(b.aux_vars[1]["hi"]), 3, "int aux 上界")
	assert_eq(b.constraints.size(), 1, "globals 应翻译出 1 条约束")

	var c: Dictionary = b.constraints[0]
	assert_eq(str(c.get("t", "")), "eq")
	var xs: Array = (c["a"] as Dictionary)["xs"]
	assert_eq(str((xs[0] as Dictionary).get("t", "")), "aux", "约束内的 aux 引用应为变量节点")
	assert_eq(int((xs[0] as Dictionary)["i"]), 0, "aux 引用应与创建顺序对齐")
	assert_eq(int((xs[1] as Dictionary)["i"]), 1, "aux 引用应与创建顺序对齐")


# 【主代理 2026-10-01】原 `test_known_gap_topo_load_and_verify_sites_not_wired`（pending）已删除：
# 该缺口已修（`core/board.gd:_compute_clues` 与 `tools/verify_batch.gd` 现在都优先问规则的
# `compute_clue_topo`），并**转成真断言**钉在 `test/unit/test_spec_end_to_end.gd`
# 的 `test_board_load_side_uses_rule_topo_clue_values` 里 —— 缺口不该以 pending 长期悬着。


func test_place_mines_returns_empty() -> void:
	var res := SpecRulePlugin.from_json(JSON.stringify(_base_spec(_uid("pm"))))
	assert_true(bool(res["ok"]), str(res["errors"]))
	var rng := RandomNumberGenerator.new()
	var mines: Array[Vector2i] = res["rule"].place_mines(rng, 5, 5, 3)
	assert_eq(mines.size(), 0, "禁暴力：place_mines 必须返回空，布雷交给 CP-SAT")
