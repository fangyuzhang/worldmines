# test_ngon_annulus_registry.gd —— 新几何族 ngon / annulus 的**登记自证**（2026-10-03）。
#
# 背景：`core-shape-geometry` 落地了 `ShapeGenerator.build_ngon`（shape_generator.gd:846）与
# `build_annulus`（:869），并把两个 kind 接进 `to_adjacency_grid`（:1155 / :1159）；但
# 「体量估算（core/editor_doc.gd:estimate_cells）」与「变体 × 网格矩阵（core/variant_grid_matrix.gd）」
# 两处登记**故意留空**（怕两份真相漂移）。本轮一次补全，本文件钉住三件事：
#   ① 估算 = **真实网格格数**（对照生产入口 `to_adjacency_grid`，不许自己跟自己比）；
#   ② 矩阵确实登记两族，且三态 / 原因 / 无退化清单与既有 12 族同口径；
#   ③ 既有 12 个生成入口 kind + 2 条结构基线的判定**未因登记而变化**（回归红线）。
extends GutTest

const M := preload("res://core/variant_grid_matrix.gd")

## 登记之前就在矩阵里的 12 个生成入口 kind（本次只许**加**两族，不许改名 / 少一个）。
const LEGACY_GENERATOR_KINDS: Array = [
	"holed_grid", "hex", "t488", "iso_cubes", "tri_grid", "trihex", "t31212", "ring",
	"circle", "star", "sector", "mask",
]

## 新增两族（与 `to_adjacency_grid` 的 match 分支逐字同名）。
const NEW_KINDS: Array = ["ngon", "annulus"]


## 真实格数：走**生产入口**（估算号称与它同口径 ⇒ 必须拿它对拍，不许自证）。
func _real_cells(kind: String, params: Dictionary) -> int:
	var g := ShapeGenerator.to_adjacency_grid(kind, params)
	if g == null:
		return 0
	return g.all_positions().size()


func _ngon_cases() -> Array:
	return [
		{"sides": 3, "radius": 4},
		{"sides": 5, "radius": 4},
		{"sides": 8, "radius": 7},
		{"sides": 12, "radius": 3},
		{"sides": 6, "radius": 5, "tier": "coarse"},     # tier 是 to_adjacency_grid 会传下去的旋钮
		{"sides": 6, "radius": 5, "tier": "fine"},
		{"sides": 6, "radius": 5, "tier": "default"},
	]


func _annulus_cases() -> Array:
	return [
		{"outer_radius": 5, "inner_radius": 2},
		{"outer_radius": 6, "inner_radius": 5},          # 洞只差一格（最薄环）
		{"outer_radius": 8, "inner_radius": 3, "precision": 16},
		{"outer_radius": 7, "inner_radius": 4},
		{"outer_radius": 7, "inner_radius": 4, "tier": "coarse"},
		{"outer_radius": 7, "inner_radius": 4, "tier": "fine"},
	]


# ==================== ① 估算 = 真实网格格数 ====================

func test_estimate_matches_the_real_grid_for_ngon_and_annulus() -> void:
	var checked := 0
	for pair in [["ngon", _ngon_cases()], ["annulus", _annulus_cases()]]:
		var kind := str(pair[0])
		for c in (pair[1] as Array):
			var params: Dictionary = c
			var real := _real_cells(kind, params)
			var est := EditorDoc.estimate_cells(kind, params, 32, 32)
			checked += 1
			assert_gt(real, 0, "前提：%s %s 应能建出非空网格" % [kind, str(params)])
			assert_eq(est, real, "%s %s：估算必须等于真实格数（估 %d / 真 %d）" % [
				kind, str(params), est, real])
	assert_gt(checked, 10, "至少要对拍 10 组以上参数，否则本用例空转（实际 %d）" % checked)


func test_estimate_is_not_a_square_fallback_for_the_new_families() -> void:
	# 用户/lead 点名的风险："未知 ⇒ 0" 或"退化成方阵口径"。三角函数族 + 环形族的估算必须**小于**
	# 同尺寸方阵（它们都挖掉了一部分格），且与包围盒面积不同。
	var rows := 16
	var cols := 16
	var box := rows * cols
	for c in [["ngon", {"sides": 6, "radius": 6}], ["annulus", {"outer_radius": 8, "inner_radius": 4}]]:
		var kind := str(c[0])
		var est := EditorDoc.estimate_cells(kind, c[1], rows, cols)
		assert_gt(est, 0, "%s 应估出正数（不是 0）" % kind)
		assert_lt(est, box, "%s 的估算不该等于方阵口径（%d vs %d）" % [kind, est, box])


func test_invalid_params_estimate_zero_and_generator_agrees() -> void:
	# 非法参数两边一致：估算 0 ⇔ 生成器建不出（免得"估得出、建不出"互相打脸）。
	var bad_cases := [
		["ngon", {"sides": 2, "radius": 4}],                 # sides < 3
		["ngon", {"sides": 5, "radius": 0}],                 # radius < 1
		["ngon", {"sides": 5, "radius": 4, "tier": "bogus"}],
		["annulus", {"outer_radius": 5, "inner_radius": 5}], # inner 必须 < outer
		["annulus", {"outer_radius": 5, "inner_radius": 6}],
		["annulus", {"outer_radius": 5, "inner_radius": 0}], # inner 必须 ≥ 1
		["annulus", {"outer_radius": 5, "inner_radius": 2, "precision": 2}],
	]
	for c in bad_cases:
		var kind := str(c[0])
		var params: Dictionary = c[1]
		assert_eq(EditorDoc.estimate_cells(kind, params, 16, 16), 0,
			"%s %s：非法参数估算应为 0" % [kind, str(params)])
		assert_eq(_real_cells(kind, params), 0,
			"%s %s：生成器同样建不出（两边口径一致）" % [kind, str(params)])


func test_annulus_really_has_a_hole_and_is_not_the_ring_family() -> void:
	# 「同名不同义」的钉子：annulus（内圆挖空的环）≠ ring（同心环盘）。洞必须真的挖掉。
	var outer := 6
	var precision := 24
	var ann := _real_cells("annulus", {"outer_radius": outer, "inner_radius": 4, "precision": precision})
	var disk := _real_cells("circle", {"radius": outer, "precision": precision})
	var ring := _real_cells("ring", {"sectors": [12], "step_deg": 30.0, "r0": 1.0, "dr": 1.0})
	assert_gt(ann, 0, "annulus 应能建盘")
	assert_gt(disk, 0, "同外径的整圆应能建盘")
	assert_gt(ring, 0, "ring（同心环盘）应能建盘")
	assert_lt(ann, disk, "annulus 必须比同外径的整圆少（内圆是洞）：ann=%d disk=%d" % [ann, disk])
	assert_ne(ann, ring, "annulus 与 ring 格数撞巧相同属可疑（两者几何不同）：%d" % ann)


func test_big_annulus_estimate_drives_warn_and_block_tiers() -> void:
	# 需求原话：大盘 annulus 的估算要能真的推动三档结论（否则"估不出来"永远落 ok）。
	# warn 档（DEFAULT_CELL_BUDGET=500）：外径 38 仍是生成器可建的上限内（_disk_upper_bound(38)=4779）。
	var big := EditorDoc.estimate_cells("annulus", {"outer_radius": 38, "inner_radius": 30}, 77, 77)
	assert_gt(big, 500, "外径 38 的环盘应已越过软预算 500（实际 %d）" % big)
	var rep := EditorDoc.check_cell_budget(big)
	assert_eq(str(rep["level"]), "warn", "越过软预算 ⇒ warn（照常执行但提示）：%d 格 → %s" % [big, str(rep)])
	assert_true(bool(rep["ok"]), "warn 档必须 ok=true（不许把警告当硬阻）")
	assert_gt((rep["hints"] as Array).size(), 0, "warn 必须给三条出路提示")
	# block 档（MAX_CELL_BUDGET=5000）：超大环盘在**估算层**必须落 block（该参数生成器会拒收，
	# 故这里只验纯函数口径：估算不许因为"算不出"而退回 0 / 方阵）。
	var huge := EditorDoc.estimate_cells("annulus", {"outer_radius": 200, "inner_radius": 190}, 401, 401)
	assert_gt(huge, 5000, "超大环盘的估算应超过硬上限（实际 %d）" % huge)
	var blocked := EditorDoc.check_cell_budget(huge)
	assert_eq(str(blocked["level"]), "block", "超过 MAX_CELL_BUDGET ⇒ block：%d 格" % huge)
	assert_false(bool(blocked["ok"]), "block 档必须 ok=false（调用方据此不执行）")


# ==================== ② 矩阵登记了两族 ====================

func test_matrix_registers_both_new_kinds() -> void:
	for k in NEW_KINDS:
		var kind := str(k)
		assert_true(M.is_known_grid_kind(kind), "矩阵必须登记 %s" % kind)
		assert_true(M.grid_kinds().has(kind), "grid_kinds() 必须含 %s" % kind)
		assert_true(M.BBOX_SUBSET_KINDS.has(kind),
			"%s 由 _outline_topo(_graph_from_dirs(cells, MOORE8)) 产出 ⇒ 属「整数格 Moore8 子集」族" % kind)
	# 三态 / 原因 / 退化清单在**两族**上都要自洽（遍历，不写死分布数字）
	for k in NEW_KINDS:
		var kind := str(k)
		var ok := 0
		var disabled := 0
		for id in VariantRegistry.all_codes():
			var st: String = M.status(id, kind)
			assert_true([M.OK, M.DEGRADED, M.DISABLED].has(st), "%s × %s 三态非法：%s" % [id, kind, st])
			if st == M.OK:
				ok += 1
				assert_eq(M.reason(id, kind), "", "%s × %s：OK 不应有原因文字" % [id, kind])
			else:
				disabled += 1
				assert_ne(M.reason(id, kind).strip_edges(), "", "%s × %s：非 OK 必须给可读原因" % [id, kind])
			assert_eq(M.degradations(id, kind).size(), 0,
				"%s × %s：当前矩阵无 DEGRADED 格 ⇒ 不得带退化清单" % [id, kind])
		assert_eq(ok + disabled, VariantRegistry.all_codes().size(), "%s：三态之和 = 变体数" % kind)
		assert_gt(disabled, 0, "%s：必须有矩形专属变体被禁用（保守：宁禁不放）" % kind)
	# 唯一 GENERIC 的 classic 在任何族上都必须 OK（包括新族）
	for kind in NEW_KINDS:
		assert_eq(M.status("classic", str(kind)), M.OK, "%s：classic 是唯一 GENERIC，必须 OK" % str(kind))


func test_new_kinds_are_gated_exactly_like_holed_grid() -> void:
	# 同族等价类：新族的每一格三态都必须与 holed_grid **逐格相同**（判据与网格族无关，只与变体声明有关）。
	var table := M.table()
	for id in VariantRegistry.all_codes():
		var row: Dictionary = table[id]
		for k in NEW_KINDS:
			var kind := str(k)
			assert_true(row.has(kind), "table() 的行必须覆盖新族 %s" % kind)
			assert_eq(str(row[kind]), str(row[M.HOLED_GRID]),
				"%s：%s 必须与 holed_grid 逐格同判（%s vs %s）" % [id, kind, str(row[kind]), str(row[M.HOLED_GRID])])


# ==================== ③ 回归红线：既有 12 族判定未变 ====================

func test_legacy_kind_judgements_did_not_change() -> void:
	# 登记新族**只许加两列**，不许动既有列的判定。这里按登记前那条语义重新复核（不是抄旧数字）：
	#   · 非矩形族上 DISABLED ⟺ 该变体只声明 GEO_RECT_ONLY（= 生成期会拦住它）；
	#   · DEGRADED 已归零（门控补齐后"包围盒强算的弱语义"不再存在）；
	#   · rect 是基线（全 OK，且无原因文字）；rect_wrap 上 GENERIC 仍 OK。
	var reg := RuleRegistry.default()
	for k in LEGACY_GENERATOR_KINDS:
		assert_true(M.is_known_grid_kind(str(k)), "既有族 %s 不得被改名 / 删除" % str(k))
	# 【2026-10-09 契约变更（期望过期，非放松）】又新增了 (p) Voronoi 不规则镶嵌 1 族
	# （core/shape_generator.gd 的 (p) 段 + to_adjacency_grid 的 voronoi 分支）。本文件为 ngon/annulus
	# 的登记自证，故只同步“族数”这一条；voronoi 的细节组断言在 test_voronoi_tiling.gd。
	assert_eq(M.grid_kinds().size(), LEGACY_GENERATOR_KINDS.size() + NEW_KINDS.size() + 1 + 2,
		"族数应恰为 12（既有生成入口）+ 2（ngon/annulus）+ 1（voronoi）+ 2（rect / rect_wrap 结构基线）")
	for id in VariantRegistry.all_codes():
		var rule: Object = reg.resolve(StringName(id))
		assert_not_null(rule, "%s 应已注册（依赖 test/_pre_run.gd 装配备用算子包）" % id)
		if rule == null:
			continue
		var rect_only := int(rule.geometry_kind()) == RulePlugin.GEO_RECT_ONLY
		for k in LEGACY_GENERATOR_KINDS:
			var kind := str(k)
			var st: String = M.status(id, kind)
			assert_eq(st == M.DISABLED, rect_only,
				"既有族 %s × %s：DISABLED 必须 ⟺ 仅矩形几何（登记新族不许影响它们）：status=%s" % [
					id, kind, st])
			assert_ne(st, M.DEGRADED, "既有族 %s × %s：DEGRADED 已归零，不许回退" % [id, kind])
	assert_eq(M.status("classic", M.RECT), M.OK, "rect 基线：classic 必须 OK")
	assert_eq(M.reason("classic", M.RECT), "", "rect 基线：语义完整 ⇒ 无原因文字")
