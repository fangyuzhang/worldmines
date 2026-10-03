# test_global_rule_gating.gd —— 全局约束型 × 异形盘（洞盘 / 环绕盘）的异形门控契约
#
# 【要治的缺陷】core/puzzle_generator.gd 原先只对**线索规则**做异形门控（回退 classic），
# 全局约束型（mx/rl/pf/qd/dt/ep/4c，全部 GEO_RECT_ONLY）在洞盘 / 环绕盘上会被**真的构建**：
# RuleBuilder 在邻接表盘上把盘外格按常量 0 代入（core/rule_builder.gd:56-59），于是约束按包围盒
# 行列强算 —— 「左右镜像」退化成「镜像列是洞的格必为 0」，运行期语义错误且判据层/生成期分叉。
#
# 【本文件钉住的四件事】
#   ① 不兼容组合（全局约束 × 洞盘 / 环绕盘）走**与线索型同一判据**的安全回退
#      （supports_topology() 为假 ⇒ 丢弃该约束，等价于未勾选 + 大声告警），
#      且**返回可读原因**（last_call_stats.gated_globals：{规则 id: 为什么}），
#      既不静默出空盘面、也不按错误语义出盘面；
#   ② 兼容组合（矩形盘 = 无 topology）行为**不变**：全局规则原样生效、没有任何门控记录；
#   ③ 回退后盘面合法：雷 / 线索格**全部落在盘内**（不存在越界的格），雷数精确、雷与线索不重叠；
#   ④ 矩阵三态与运行期**逐格一致**（遍历断言：matrix.status() 的 DISABLED ⟺ 生成期门控判据，
#      不写死任何数字 / 名单 —— 名单由 get_kind() 遍历得出）。
#
# 依赖 test/_pre_run.gd 装配的「备用算子包」（ep / 4c 来自 demo/mods/legacy_rules）——
# 少了它们，全局型变体集合会缩水，①④ 会失去一半覆盖（本文件对此显式断言，不静默放行）。
extends GutTest

const M := preload("res://core/variant_grid_matrix.gd")

## 洞盘：6×6 挖掉中央 2×2（32 格存活），洞格删格删边、不重连（ShapeGenerator.build_holed_grid 口径）。
const HOLES: Array = [Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 3)]
## 门控在生成期发生，与「能否生成」无关 ⇒ 多 seed 重试只为拿到一盘做③的落盘校验，避免假红。
const SEEDS: Array = [5, 105, 205]


# ==================== 夹具 ====================

func _irregular_boards() -> Dictionary:
	return {"holed": _holed_topo(), "wrap": _wrap_topo()}


## 本文件的棋盘标签 → 矩阵网格族名（两套名字不同，不许混用：混了会静默落到「未知族 ⇒ DISABLED」）。
func _matrix_kind(label: String) -> String:
	return M.RECT_WRAP if label == "wrap" else M.HOLED_GRID


func _holed_topo() -> AdjacencyGrid:
	return ShapeGenerator.to_adjacency_grid("holed_grid", {"rows": 6, "cols": 6, "holes": HOLES})


func _wrap_topo() -> AdjacencyGrid:
	var built: Dictionary = WrapTopology.build(6, 6, [], false, true, true)
	if not bool(built.get("ok", false)):
		return null
	var g := AdjacencyGrid.new()
	g.setup_from_topo(built["topology"])
	return g


## 遍历 VariantRegistry 得出「全局约束型变体码」（不写死名单：注册表一变，本测试随之覆盖）。
func _global_variant_ids() -> Array[String]:
	var out: Array[String] = []
	var reg := RuleRegistry.default()
	for id in VariantRegistry.all_codes():
		var r: Object = reg.resolve(StringName(id))
		if r != null and str(r.call("get_kind")) == RulePlugin.KIND_GLOBAL:
			out.append(id)
	return out


func _mines_for(topo: GridInterface) -> int:
	return maxi(1, int(topo.cell_count() * 0.25))


## 多 seed 生成（门控发生在选 seed 之前，故此循环只影响「是否拿到一盘」）。
## 返回最后一轮的 stats —— 门控记录与生成成功与否无关，不能因没出关就丢掉它。
func _generate(clue_id: String, globals: Array, topo: Variant, size: Vector2i, mines: int) -> Dictionary:
	var last_stats := {}
	for s in SEEDS:
		var gen := PuzzleGenerator.new()
		var lv: Dictionary = gen.generate_with_rules(clue_id, globals, size, mines, int(s), 0, 20, topo, 30_000)
		last_stats = gen.last_call_stats
		if not lv.is_empty():
			return {"lv": lv, "stats": last_stats}
	return {"lv": {}, "stats": last_stats}


# ==================== ① 不兼容组合：安全回退 + 可读原因 ====================

func test_irregular_boards_safely_drop_gated_globals_with_readable_reason() -> void:
	var gids := _global_variant_ids()
	assert_gt(gids.size(), 0, "至少要有一个全局约束型变体（否则本用例空转）")
	print("    [全局约束型] %s" % str(gids))

	for kind in ["holed", "wrap"]:
		var topo: GridInterface = _irregular_boards()[kind]
		assert_not_null(topo, "%s 棋盘应能构造（本用例的判据载体）" % kind)
		if topo == null:
			continue
		for gid in gids:
			var res := _generate("classic", [gid], topo, topo.size(), _mines_for(topo))
			var gated: Dictionary = (res["stats"] as Dictionary).get("gated_globals", {})
			# 可读原因是门控生效的**唯一证据**（生成成功与否是另一回事，不能拿它代替）
			assert_true(gated.has(gid),
					"%s × %s：不兼容的全局约束必须被门控并留下可读原因；stats=%s" % [gid, kind, str(res["stats"])])
			if not gated.has(gid):
				continue
			var why := str(gated[gid]).strip_edges()
			assert_gt(why.length(), 0, "%s × %s：门控原因不得为空" % [gid, kind])
			assert_true(why.contains("矩形") or why.contains("包围盒"),
					"%s × %s：原因必须说清「为什么不能要」；实际=%s" % [gid, kind, why])
			var lv: Dictionary = res["lv"]
			if lv.is_empty():
				# 生成失败属其它阶段（换 seed 只能碰运气）——门控已证实生效，不在此判红。
				print("      （%s × %s：门控生效但该次未出关，跳过落盘校验）" % [gid, kind])
				continue
			# 安全回退 = 丢弃该约束 ⇒ 落盘名单必须同步，不得自述「带一个没生效的约束」
			assert_false(Array(lv["global_rules"]).has(gid),
					"%s × %s：被门控的全局规则不得出现在落盘 global_rules；实际=%s" % [
						gid, kind, str(lv["global_rules"])])
			if gid == "dt":
				assert_false(lv.has("dominoes"), "%s：dt 被丢弃后不得落盘 dominoes（骨牌划分）" % kind)


# ==================== ② 兼容组合（矩形盘）行为不变 ====================

func test_rect_baseline_is_untouched() -> void:
	var gids := _global_variant_ids()
	var size := Vector2i(6, 6)
	for gid in gids:
		# 先问判据层要一个可行雷数（矩形口径，与门控无关；不同约束的可行雷数不同）
		var mines := -1
		for m in range(4, 21):
			if bool(PuzzleGenerator.precheck_rules("classic", [gid], size, m)["ok"]):
				mines = m
				break
		assert_gt(mines, 0, "%s：矩形盘上应存在可行雷数（否则本用例对它空转）" % gid)
		if mines <= 0:
			continue
		var res := _generate("classic", [gid], null, size, mines)
		var gated: Dictionary = (res["stats"] as Dictionary).get("gated_globals", {})
		assert_true(gated.is_empty(),
				"矩形盘（无 topology，不走生成期异形门控）不得产生任何门控记录：%s → %s" % [gid, str(gated)])
		var lv: Dictionary = res["lv"]
		assert_false(lv.is_empty(), "矩形盘上 %s@%d 雷应能出关（兼容组合行为不许变）" % [gid, mines])
		if lv.is_empty():
			continue
		assert_true(Array(lv["global_rules"]).has(gid),
				"矩形盘上全局规则必须原样生效（行为不许变）：%s；实际=%s" % [gid, str(lv["global_rules"])])


# ==================== ③ 回退后盘面合法 ====================

func test_board_stays_legal_after_fallback() -> void:
	for kind in ["holed", "wrap"]:
		var topo: GridInterface = _irregular_boards()[kind]
		if topo == null:
			fail_test("%s 棋盘构造失败" % kind)
			continue
		var in_board := {}
		for p in topo.all_positions():
			in_board[p] = true
		var want := _mines_for(topo)
		var res := _generate("classic", ["mx", "pf"], topo, topo.size(), want)
		var lv: Dictionary = res["lv"]
		assert_false(lv.is_empty(), "%s：兼容的线索规则 + 被门控的全局规则应仍能出关；stats=%s" % [kind, str(res["stats"])])
		if lv.is_empty():
			continue
		var mines := {}
		for m in lv["mines"]:
			var p := Vector2i(int(m["c"]), int(m["r"]))
			assert_true(in_board.has(p), "%s：雷必须落在盘内（不存在越界的格）：%s" % [kind, str(p)])
			assert_false(mines.has(p), "%s：雷位不得重复：%s" % [kind, str(p)])
			mines[p] = true
		for rec in lv["revealed"]:
			var p := Vector2i(int(rec["c"]), int(rec["r"]))
			assert_true(in_board.has(p), "%s：线索格必须落在盘内（不存在越界的格）：%s" % [kind, str(p)])
			assert_false(mines.has(p), "%s：线索格不得同时是雷：%s" % [kind, str(p)])
		assert_eq(mines.size(), want, "%s：实际雷数必须等于请求值（回退不改雷数契约）" % kind)
		# 回退后盘面 = 纯 classic 异形盘：矩阵里 classic 在该族上是 OK ⇒ 两处口径必须一致
		assert_eq(M.status("classic", _matrix_kind(kind)), M.OK,
				"%s：classic 在异形族上应是 OK（回退目标本身可用，否则回退后仍不可玩）" % kind)


# ==================== ④ 矩阵三态 ⟺ 运行期门控（遍历断言） ====================

func test_matrix_tristate_matches_runtime_gate() -> void:
	var reg := RuleRegistry.default()
	var checked := 0
	var disabled_cells := 0
	var global_checked := 0
	for id in VariantRegistry.all_codes():
		var rule: Object = reg.resolve(StringName(id))
		assert_not_null(rule, "变体 %s 必须已注册（_pre_run 应已装配备用算子包）" % id)
		if rule == null:
			continue
		checked += 1
		if str(rule.call("get_kind")) == RulePlugin.KIND_GLOBAL:
			global_checked += 1
		# 运行期判据 = 生成期门控自己用的那个函数（不是测试自造的同义实现）
		var runtime_ok := PuzzleGenerator._rule_topology_ok(rule)
		for k in M.grid_kinds():
			var gk := str(k)
			var st := M.status(id, gk)
			assert_true([M.OK, M.DEGRADED, M.DISABLED].has(st), "%s × %s 三态非法：%s" % [id, gk, st])
			if gk == M.RECT:
				continue   # rect = 无 topology 基线盘，生成期不做门控（永远 OK，另一条契约）
			# 核心一致性：DISABLED ⟺ 生成期会拦住它（runtime_ok = 生成期门控判据本身）。
			# DEGRADED 若出现，它与「已经会被拦住」矛盾 ⇒ 本断言必红（这正是要求④要钉的分叉）。
			var msg := "%s × %s：矩阵三态必须与运行期门控一致 —— status=%s, 生成期放行=%s" % [
					id, gk, st, str(runtime_ok)]
			assert_eq(st != M.DISABLED, runtime_ok, msg)
			if st == M.DISABLED:
				disabled_cells += 1
				assert_gt(M.reason(id, gk).strip_edges().length(), 0, "DISABLED 必须带可读原因：%s × %s" % [id, gk])
				assert_eq(M.degradations(id, gk).size(), 0, "DISABLED 不得带退化清单：%s × %s" % [id, gk])
			else:
				assert_eq(M.degradations(id, gk).size(), 0, "非 DEGRADED 不得带退化清单：%s × %s" % [id, gk])
	assert_eq(checked, VariantRegistry.all_codes().size(), "全部内置变体都应已注册")
	assert_gt(global_checked, 0, "矩阵必须至少覆盖一个全局约束型（否则本文件空转）")
	assert_gt(disabled_cells, 0, "异形族上必须有被禁用的组合（否则门控没进矩阵）")


# ==================== 补充：缺格族等价类 + 判据层同口径 ====================

func test_bbox_subset_kinds_are_gated_identically() -> void:
	# circle / star / sector 与 holed_grid 同属「整数格上 Moore 8 邻的子集」：门控判据与网格族无关，
	# 故四族必须**逐格同判**（按 BBOX_SUBSET_KINDS 遍历，不写死数字）。
	for id in VariantRegistry.all_codes():
		var row: Dictionary = M.table().get(id, {})
		for k in M.BBOX_SUBSET_KINDS:
			assert_true(row.has(str(k)), "缺格族 %s 必须在矩阵里：%s" % [str(k), id])
			assert_eq(str(row[str(k)]), M.status(id, M.HOLED_GRID),
					"%s：缺格族 %s 必须与 holed_grid 逐格同判" % [id, str(k)])


func test_precheck_and_generate_agree_on_gated_globals() -> void:
	# 判据层（precheck）与生成期必须同口径：门控把规则丢掉后，判据结论应与「本来就没勾它」相同。
	var gids := _global_variant_ids()
	assert_gt(gids.size(), 0, "至少要有一个全局约束型变体")
	for kind in ["holed", "wrap"]:
		var topo: GridInterface = _irregular_boards()[kind]
		if topo == null:
			continue
		for gid in gids:
			var with_g: Dictionary = PuzzleGenerator.precheck_rules("classic", [gid], topo.size(), _mines_for(topo), topo)
			var without: Dictionary = PuzzleGenerator.precheck_rules("classic", [], topo.size(), _mines_for(topo), topo)
			assert_eq(bool(with_g["ok"]), bool(without["ok"]),
					"%s × %s：被门控的全局规则不得改变判据结论（否则判据层与生成期分叉）：%s vs %s" % [
						gid, kind, str(with_g), str(without)])
