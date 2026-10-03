# test_variant_grid_matrix.gd —— 变体 × 网格族兼容矩阵的门禁用例
#
# 覆盖（对应 W9「勾选即时禁用」的硬约束）：
#   ① 覆盖性：VariantRegistry.all_codes() 里**每一个**真实变体在矩阵里都有条目，
#      且矩阵不许多出条目（**按注册表遍历**，不硬编变体列表）；
#   ② 矩形盘（rect）上不得出现 DISABLED；
#   ③ 任何 DEGRADED 必须带非空原因 + 非空退化清单；非 DEGRADED 不得带退化清单。
#      【2026-10-03 契约变更】生成期补齐全局约束门控后，本表 DEGRADED 归零（全局约束型在异形族上
#      会被真的拦住）⇒ ③ 现在是对全表的**充要关系**（当前无实例），而「全局约束型 × 非矩形族
#      一律 DISABLED」改由遍历断言钉住（见 test_degraded_cells_have_reason_and_list）；
#   ④ 未知变体 / 未知网格族查询走兜底（DISABLED + 非空原因，不崩）；
#   ⑤ 交叉校验（防止本表与代码漂移）：矩阵声明的 geometry 必须与规则自己的
#      RulePlugin.geometry_kind() 同向；OK ⟺ 声明 GEO_ADJ_GENERIC；
#   ⑥ 网格族名单必须覆盖 ShapeGenerator.to_adjacency_grid 的全部 kind；mask 取 style 最保守者。
#
# 依赖 test/_pre_run.gd 装配的「备用算子包」（4n/sc/fr/distsum/hv/ep/4c）——⑤⑧ 需要它们的实时声明。
extends GutTest

const M := preload("res://core/variant_grid_matrix.gd")

## 镜像 `core/shape_generator.gd` 的 to_adjacency_grid match 分支
## （该方法没有 kinds() 访问器，故在此列举；漂移时 ⑥ 会红）。
## 2026-10-03：新增 (j)~(l) 参数化轮廓族 circle / star / sector 后，名单随代码同步扩充——
## 这是**契约变更**（族数 9 → 12），不是放松断言：⑥ 仍要求矩阵族与生成入口双向一一对应。
const GENERATOR_KINDS: Array = [
	"holed_grid", "hex", "t488", "iso_cubes", "tri_grid", "trihex", "t31212", "ring",
	"circle", "star", "sector", "mask",
]


func test_every_registry_variant_is_declared() -> void:
	var registry := VariantRegistry.all_codes()
	var declared := M.variant_ids()
	assert_eq(declared.size(), registry.size(),
			"矩阵登记数必须等于 VariantRegistry 的变体数（注册表：%s）" % str(registry))
	for id in registry:
		assert_true(declared.has(id), "变体 %s 在矩阵里必须有条目" % id)
	for id in declared:
		assert_true(registry.has(id), "矩阵多出注册表里没有的条目 %s" % id)


func test_all_cells_are_tristate() -> void:
	for id in VariantRegistry.all_codes():
		for k in M.grid_kinds():
			var st := M.status(id, k)
			assert_true([M.OK, M.DEGRADED, M.DISABLED].has(st),
					"%s × %s 的三态非法：%s" % [id, k, st])


func test_rect_has_no_disabled() -> void:
	for id in VariantRegistry.all_codes():
		assert_ne(M.status(id, M.RECT), M.DISABLED,
				"矩形盘（rect）上 %s 不得被禁用——变体的定义域就是矩形盘" % id)
		assert_eq(M.reason(id, M.RECT), "", "rect 上语义完整，不应有原因文字：%s" % id)


func test_degraded_cells_have_reason_and_list() -> void:
	var degraded := 0
	for id in VariantRegistry.all_codes():
		for k in M.grid_kinds():
			var st := M.status(id, k)
			var r := M.reason(id, k)
			var d := M.degradations(id, k)
			if st == M.DEGRADED:
				degraded += 1
				assert_ne(r.strip_edges(), "", "DEGRADED 必须带非空原因：%s × %s" % [id, k])
				assert_gt(d.size(), 0, "DEGRADED 必须带非空退化清单：%s × %s" % [id, k])
				for line in d:
					assert_ne(str(line).strip_edges(), "", "退化说明不得为空：%s × %s" % [id, k])
			else:
				assert_eq(d.size(), 0,
						"非 DEGRADED 不得带退化清单（状态 = %s）：%s × %s" % [st, id, k])
			if st == M.DISABLED:
				assert_ne(r.strip_edges(), "", "DISABLED 必须带非空原因：%s × %s" % [id, k])
	# ---- 【2026-10-03 契约变更，主代理指派】----
	# 旧断言：`assert_gt(degraded, 0, "...否则「退化定义」这一态形同虚设")`。
	# 变更原因（不是为凑绿）：生成期补齐了全局约束型的异形门控（core/puzzle_generator.gd:473-498），
	# 7 个全局约束型在缺格族 / 环绕族上**会被真的拦住**（约束被丢弃，等价于未勾选）
	# ⇒ 「按包围盒强算仍可解释为较弱语义」不再成立 ⇒ 这些格由 DEGRADED 转 DISABLED
	# （矩阵 35 个 DEGRADED 格 → 0）。
	# 新断言（仍是**遍历派生**，不写死任何数字）：全局约束型在**每个**非矩形族上必须 DISABLED；
	# 若将来某格重新出现 DEGRADED，上面的循环已强制它带非空原因 + 非空清单（充要关系不变）。
	var global_disabled := 0
	var reg := RuleRegistry.default()
	for id in VariantRegistry.all_codes():
		var rule: Object = reg.resolve(StringName(id))
		if rule == null or str(rule.call("get_kind")) != RulePlugin.KIND_GLOBAL:
			continue
		for k in M.grid_kinds():
			if k == M.RECT:
				continue
			global_disabled += 1
			assert_eq(M.status(id, str(k)), M.DISABLED,
					"全局约束型 %s 在 %s 上必须 DISABLED（生成期门控会丢弃它）：%s" % [
						id, str(k), M.reason(id, str(k))])
	assert_gt(global_disabled, 0, "矩阵必须覆盖「全局约束型 × 非矩形族」（否则本断言空转）")
	assert_eq(degraded, 0,
			"门控补齐后本表不应再有 DEGRADED 格（弱语义已不存在；实际 %d 格 —— 出现了就要核对它是真弱语义还是漏门控）" % degraded)


func test_unknown_variant_and_grid_fall_back_to_disabled() -> void:
	assert_eq(M.status("no_such_variant", M.RECT), M.DISABLED)
	assert_ne(M.reason("no_such_variant", M.RECT).strip_edges(), "")
	for bad_kind in ["voronoi", "", "hex6", "union", "rect_wap"]:
		assert_eq(M.status("classic", bad_kind), M.DISABLED,
				"未登记的网格族 %s 必须兜底为 DISABLED" % str(bad_kind))
		assert_ne(M.reason("classic", bad_kind).strip_edges(), "",
				"未登记的网格族 %s 必须给出原因" % str(bad_kind))
	assert_eq(M.status("", ""), M.DISABLED, "双空查询也不得崩")
	assert_eq(M.enabled_variants("voronoi").size(), 0, "未知族上没有可用变体")


func test_declared_geometry_matches_rule_plugin() -> void:
	var registry := RuleRegistry.default()
	var checked := 0
	for id in VariantRegistry.all_codes():
		var rule: Object = registry.resolve(StringName(id))
		if rule == null:
			continue
		checked += 1
		var generic := int(rule.geometry_kind()) == RulePlugin.GEO_ADJ_GENERIC
		for k in M.grid_kinds():
			if k == M.RECT:
				continue
			assert_eq(M.status(id, k) == M.OK, generic,
					"%s 的矩阵状态必须与它的 geometry_kind() 同向（%s 上 OK 只能给 GEO_ADJ_GENERIC）" % [id, k])
	assert_eq(checked, VariantRegistry.all_codes().size(),
			"全部内置变体都应已注册（test/_pre_run.gd 应已装配备用算子包）")


func test_grid_kinds_cover_generator_entry_points() -> void:
	for k in GENERATOR_KINDS:
		assert_true(M.grid_kinds().has(str(k)),
				"ShapeGenerator.to_adjacency_grid 的 kind %s 必须在矩阵里" % str(k))
	for k in M.grid_kinds():
		assert_true(GENERATOR_KINDS.has(k) or k == M.RECT or k == M.RECT_WRAP,
				"矩阵多出未对应任何生成入口的族 %s" % k)


func test_mask_is_worst_case_of_its_styles() -> void:
	assert_eq(M.MASK_STYLE_KINDS.size(), ShapeGenerator.MASK_STYLES.size(),
			"mask 的 style 名单应与 ShapeGenerator.MASK_STYLES 同步")
	for k in ShapeGenerator.MASK_STYLES:
		assert_true(M.MASK_STYLE_KINDS.has(str(k)), "矩阵的 mask style 缺 %s" % str(k))
	var sev := {M.OK: 0, M.DEGRADED: 1, M.DISABLED: 2}
	for id in VariantRegistry.all_codes():
		var worst := 0
		for k in M.MASK_STYLE_KINDS:
			worst = maxi(worst, int(sev[M.status(id, str(k))]))
		assert_eq(int(sev[M.status(id, M.MASK)]), worst,
				"mask 必须取 style 三族的最保守状态：%s" % id)


func test_enabled_and_disabled_partition_variants() -> void:
	for k in M.grid_kinds():
		var en := M.enabled_variants(k)
		var dis := M.disabled_variants(k)
		assert_eq(en.size() + dis.size(), VariantRegistry.all_codes().size(),
				"%s：可用 + 禁用必须恰好覆盖全部变体" % k)
		for id in VariantRegistry.all_codes():
			assert_eq(en.has(id), M.status(id, k) != M.DISABLED,
					"%s × %s：enabled_variants 与 status 不一致" % [id, k])
			assert_eq(dis.has(id), M.status(id, k) == M.DISABLED,
					"%s × %s：disabled_variants 与 status 不一致" % [id, k])


func test_rect_wrap_follows_the_topology_gate() -> void:
	# 环绕矩形盘的格子仍是方格，但只要关卡带 topology 就走 AdjacencyGrid
	# （core/wrap_topology.gd:51-108 ⇒ core/board.gd:164-171），故线索型被生成期回退经典
	# （core/puzzle_generator.gd:463-472）、全局约束型被丢弃（core/puzzle_generator.gd:473-498）。
	# 与「rect 上不得 DISABLED」不矛盾：rect 是**无 topology**的基线盘。
	assert_eq(M.status("classic", M.RECT_WRAP), M.OK, "classic 是唯一 GENERIC，环绕盘上仍完整")
	var disabled := M.disabled_variants(M.RECT_WRAP)
	var degraded := 0
	for id in VariantRegistry.all_codes():
		if M.status(id, M.RECT_WRAP) == M.DEGRADED:
			degraded += 1
	for id in disabled:
		var r := M.reason(id, M.RECT_WRAP)
		assert_true(r.contains("回退") or r.contains("丢弃") or r.contains("不存在"),
				"环绕盘上被禁用必须写明原因（生成期回退 / 丢弃 / 无几何轴）：%s → %s" % [id, r])
	assert_gt(disabled.size(), 0, "环绕盘上应有被禁用的变体，否则门控未被矩阵覆盖")
	# ---- 【2026-10-03 契约变更，主代理指派】----
	# 旧断言：`assert_gt(degraded, 0, "环绕盘上应有退化可用的全局约束（如 rl 环不闭合）")`。
	# 变更原因：全局约束型在环绕盘上此前「无门控 ⇒ 会被原样构建」所以是 DEGRADED；补齐门控后
	# 生成期会丢弃它，与其余异形族同判 ⇒ DEGRADED 归零。新断言（遍历派生，不写死数字）：
	# 环绕盘上 DISABLED ⟺ 该变体声明仅矩形几何（GEO_RECT_ONLY）。
	var reg := RuleRegistry.default()
	for id in VariantRegistry.all_codes():
		var rule: Object = reg.resolve(StringName(id))
		if rule == null:
			continue
		var rect_only := int(rule.geometry_kind()) == RulePlugin.GEO_RECT_ONLY
		assert_eq(M.status(id, M.RECT_WRAP) == M.DISABLED, rect_only,
				"环绕盘上 DISABLED 只能来自「声明仅矩形几何」：%s（status=%s）" % [id, M.status(id, M.RECT_WRAP)])
	assert_eq(degraded, 0, "门控补齐后环绕盘上不再有 DEGRADED（弱语义已不存在）")


func test_table_counts_are_consistent() -> void:
	var t := M.table()
	assert_eq(t.size(), VariantRegistry.all_codes().size(), "table() 覆盖全部变体")
	var counts := {M.OK: 0, M.DEGRADED: 0, M.DISABLED: 0}
	for id in t:
		var row: Dictionary = t[id]
		assert_eq(row.size(), M.grid_kinds().size(), "%s 的行必须覆盖全部网格族" % id)
		for k in row:
			counts[str(row[k])] = int(counts[str(row[k])]) + 1
	var total := int(counts[M.OK]) + int(counts[M.DEGRADED]) + int(counts[M.DISABLED])
	assert_eq(total, VariantRegistry.all_codes().size() * M.grid_kinds().size(), "三态之和 = 格子总数")
	assert_gt(int(counts[M.OK]), 0, "至少矩形盘上是 OK")
	assert_gt(int(counts[M.DISABLED]), 0, "矩阵必须有禁用格（异形族上的矩形专属变体）")
	print("[matrix] OK=%d DEGRADED=%d DISABLED=%d（%d 变体 × %d 网格族 = %d 格）" % [
			int(counts[M.OK]), int(counts[M.DEGRADED]), int(counts[M.DISABLED]),
			VariantRegistry.all_codes().size(), M.grid_kinds().size(), total])
