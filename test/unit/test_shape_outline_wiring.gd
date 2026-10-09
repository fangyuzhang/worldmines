# test_shape_outline_wiring.gd —— (j)~(l) 参数化轮廓族「接通」门禁：生成入口 / 兼容矩阵 / 编辑器 UI
#
# 背景：`build_circle` / `build_star` / `build_sector` 早就在 `core/shape_generator.gd` 里，
# 但**没被注册**——于是 ① `to_adjacency_grid` 不认这三族（用户根本选不到）；
# ② `VariantGridMatrix` 的网格族名单漏掉它们（与生成入口静默漂移）；
# ③ 编辑器形状下拉只有 3 项。本文件把三条接线锁死，防再次断开：
#   A. 注册：`to_adjacency_grid(kind, params)` 解析三族，且与直接 `build_*` 逐字段一致；
#   B. 矩阵：新族进 `grid_kinds()`，三态 / 原因 / 退化清单自洽——**一律遍历断言，不写死分布数字**
#      （族数变了、分布变了都不许崩，只要求内部自洽且不静默漂移）；
#   C. UI：下拉能选到三族、正确写入 `doc.shape_kind`/`shape_params`、盘真能建出来；
#      超预算请求被既有闸门 `_budget_allows` 拦住（不动文档）。
#
# 判界/遍历一律 `all_positions()` 口径（core/adjacency_grid.gd 的公开 API）。
extends GutTest

const M := preload("res://core/variant_grid_matrix.gd")

## 新族（(j)~(l)）：kind → 参数（与 UI 的默认值一致）。
const OUTLINE_DEFAULTS := {
	"circle": {"radius": 4, "precision": 24},
	"star": {"points": 5, "outer_radius": 4, "inner_ratio": 0.5},
	"sector": {"radius": 4, "start_deg": 0.0, "end_deg": 90.0},
}


# ==================== 工具 ====================

func _k(p: Vector2i) -> String:
	return "%d,%d" % [p.x, p.y]


func _positions_of(topo: Dictionary) -> Dictionary:
	var s := {}
	for v: Variant in (topo.get("positions", []) as Array):
		s[Vector2i(int(v["x"]), int(v["y"]))] = true
	return s


## 独立数邻接表边数（同时顺带断言邻接对称）——不依赖被测入口的内部结构。
func _grid_edge_count(g: GridInterface) -> int:
	var total := 0
	for p in g.all_positions():
		for nb in g.get_neighbors(p):
			assert_true(g.get_neighbors(nb).has(p), "邻接不对称 %s→%s" % [_k(p), _k(nb)])
			total += 1
	return total / 2


func _build_direct(kind: String, p: Dictionary) -> Dictionary:
	match kind:
		"circle":
			return ShapeGenerator.build_circle(int(p["radius"]), int(p.get("precision", 24)))
		"star":
			return ShapeGenerator.build_star(int(p["points"]), int(p["outer_radius"]),
					float(p.get("inner_ratio", 0.5)))
		"sector":
			return ShapeGenerator.build_sector(int(p["radius"]), float(p["start_deg"]),
					float(p["end_deg"]))
	return {}


func _make_editor() -> Object:
	var scene: PackedScene = load("res://ui/level_editor.tscn")
	assert_not_null(scene, "编辑器场景应能加载")
	var ed: Object = scene.instantiate()
	add_child_autofree(ed as Node)
	return ed


# ==================== A. 注册：三族经 to_adjacency_grid 与直接构建一致 ====================

func test_outline_kinds_are_registered_and_match_direct_builds() -> void:
	for kind in OUTLINE_DEFAULTS:
		var params: Dictionary = OUTLINE_DEFAULTS[kind]
		var direct := _build_direct(kind, params)
		assert_gt(_positions_of(direct).size(), 0, "%s：直接构建应有格" % kind)
		var g := ShapeGenerator.to_adjacency_grid(kind, params)
		assert_not_null(g, "%s 必须能被 to_adjacency_grid 解析（此前未注册 ⇒ 用户选不到）" % kind)
		var want := _positions_of(direct)
		var got := {}
		for p in g.all_positions():
			got[p] = true
		assert_eq(got.size(), want.size(), "%s：入口格数应与 build_* 一致" % kind)
		for p in want:
			assert_true(got.has(p), "%s：入口缺格 %s" % [kind, _k(p)])
		assert_eq(_grid_edge_count(g), (direct.get("adjacency", []) as Array).size(),
				"%s：入口边数应与 build_* 一致" % kind)
		assert_eq(g.style, str(direct["style"]), "%s：style 应贯通（渲染 / 落盘都从它取）" % kind)
		assert_eq(g.style_params, direct["params"], "%s：params 应贯通" % kind)


func test_outline_kinds_reject_invalid_params_through_entry_point() -> void:
	# 统一入口对非法参数仍走 build_* 的拒绝分支（返回 null + push_error，不产半成品）。
	for kind in OUTLINE_DEFAULTS:
		var bad: Dictionary = (OUTLINE_DEFAULTS[kind] as Dictionary).duplicate()
		# 把「半径/外半径」改成 0 ⇒ 三族的半径校验都应拒绝。
		var radius_key := "outer_radius" if kind == "star" else "radius"
		bad[radius_key] = 0
		assert_true(ShapeGenerator.to_adjacency_grid(kind, bad) == null,
				"%s：非法参数（%s=0）应返回 null" % [kind, radius_key])


# ==================== B. 矩阵：新族进名单 + 三态自洽（遍历，不写死数字） ====================

func test_matrix_declares_outline_kinds() -> void:
	var seen := {}
	for k in M.grid_kinds():
		assert_false(seen.has(k), "grid_kinds() 不得有重复：%s" % str(k))
		seen[k] = true
	for kind in OUTLINE_DEFAULTS:
		assert_true(M.is_known_grid_kind(kind), "矩阵必须登记新网格族 %s" % kind)
		assert_true(M.grid_kinds().has(kind), "grid_kinds() 必须含 %s" % kind)


func test_matrix_outline_columns_are_self_consistent_tristate() -> void:
	var registry: Array = VariantRegistry.all_codes()
	assert_gt(registry.size(), 0, "应能取到变体注册表（依赖 test/_pre_run.gd 装配）")
	for kind in OUTLINE_DEFAULTS:
		var ok := 0
		var degraded := 0
		var disabled := 0
		for id in registry:
			var st: String = M.status(id, kind)
			assert_true([M.OK, M.DEGRADED, M.DISABLED].has(st),
					"%s × %s 三态非法：%s" % [id, kind, st])
			var r: String = M.reason(id, kind)
			var d: Array = M.degradations(id, kind)
			if st == M.OK:
				ok += 1
				assert_eq(r, "", "%s × %s：OK 不应有原因文字" % [id, kind])
				assert_eq(d.size(), 0, "%s × %s：OK 不得有退化清单" % [id, kind])
			elif st == M.DEGRADED:
				degraded += 1
				assert_ne(r.strip_edges(), "", "%s × %s：DEGRADED 必须带非空原因" % [id, kind])
				assert_gt(d.size(), 0, "%s × %s：DEGRADED 必须带非空退化清单" % [id, kind])
			else:
				disabled += 1
				assert_ne(r.strip_edges(), "", "%s × %s：DISABLED 必须带非空原因" % [id, kind])
				assert_eq(d.size(), 0, "%s × %s：DISABLED 不得带退化清单" % [id, kind])
		# 遍历断言（不写死数字）：划分完整、与 enabled/disabled 派生态一致、且分布非退化。
		assert_eq(ok + degraded + disabled, registry.size(), "%s：三态之和 = 变体数" % kind)
		assert_eq(M.enabled_variants(kind).size(), ok + degraded,
				"%s：enabled_variants 应与 status 一致" % kind)
		assert_eq(M.disabled_variants(kind).size(), disabled,
				"%s：disabled_variants 应与 status 一致" % kind)
		# ---- 【2026-10-03 契约变更（team-lead 授权，矩阵三态 owner 收口）】----
		# 旧断言：`assert_gt(degraded, 0, "%s：应有全局约束型退化可用（否则矩阵对全局轴无表达）")`。
		# 变更依据（运行期事实）：生成期补齐了**全局约束型**的异形门控
		# （core/puzzle_generator.gd:473-498）——凡未声明 supports_topology() 的全局规则
		# （即 GEO_RECT_ONLY：mx/rl/pf/qd/dt/ep/4c 及所有 demo/mods 全局算子）在带 topology 的盘上
		# **会被硬拦**：约束被丢弃（等价于未勾选）+ 告警 + 可读原因（last_call_stats.gated_globals）。
		# 故原先「按包围盒强算（rule_builder.gd:56-59）仍可解释为较弱语义」的 DEGRADED 不再成立
		# ⇒ 这三族的 DEGRADED 归零、转 DISABLED。
		# 旧断言背后的设计诉求（"矩阵必须对全局轴有表达，不能全 OK 也不能全禁"）**没有丢**，
		# 改由「门控 + 逐条可读原因」承担 —— 即下面这两条遍历断言（不写死分布数字，不放松容忍度）。
		var reg := RuleRegistry.default()
		var global_seen := 0
		for id in registry:
			var rule: Object = reg.resolve(StringName(id))
			assert_not_null(rule, "%s：变体必须已注册（依赖 test/_pre_run.gd 装配）" % id)
			if rule == null:
				continue
			var rect_only := int(rule.geometry_kind()) == RulePlugin.GEO_RECT_ONLY
			assert_eq(M.status(id, kind) == M.DISABLED, rect_only,
					"%s × %s：DISABLED 必须 ⟺ 该变体声明仅矩形几何（GEO_RECT_ONLY）；status=%s" % [
						id, kind, M.status(id, kind)])
			if str(rule.call("get_kind")) == RulePlugin.KIND_GLOBAL:
				global_seen += 1
				assert_eq(M.status(id, kind), M.DISABLED,
						"%s × %s：全局约束型在新族上必须 DISABLED（运行期会丢弃它）；原因=%s" % [
							id, kind, M.reason(id, kind)])
		assert_gt(global_seen, 0,
				"%s：注册表里必须有全局约束型，否则「矩阵对全局轴有表达」这条根本没被验证" % kind)
		assert_gt(disabled, 0,
				"%s：应有矩形专属线索型被禁用（保守：宁禁不放，不许把未证语义标 OK）" % kind)
		print("[outline-matrix] %s: OK=%d DEGRADED=%d DISABLED=%d" % [kind, ok, degraded, disabled])


func test_matrix_only_generic_variant_is_ok_on_outline_kinds() -> void:
	# OK ⟺ 该变体在任意拓扑上语义完整（GENERIC）。用既有异形族 hex 作对照：
	# 新族的 OK 集合必须与 hex 的 OK 集合一致 —— 不写死"只有 classic"，只查自洽。
	var registry: Array = VariantRegistry.all_codes()
	for kind in OUTLINE_DEFAULTS:
		for id in registry:
			assert_eq(M.status(id, kind) == M.OK, M.status(id, M.HEX) == M.OK,
					"%s × %s：OK 集合应与既有异形族 hex 一致（只有声明 GENERIC 者可用）" % [id, kind])
	# 明确锚点：classic 是矩阵里唯一的 GENERIC，在任何族上都应 OK。
	for kind in M.grid_kinds():
		assert_eq(M.status("classic", kind), M.OK, "%s：classic 必须 OK（唯一 GENERIC）" % kind)


func test_matrix_unknown_outline_like_kinds_still_fall_back() -> void:
	# 不猜语义：未登记的相近名字（如布尔复合格 / 双曲镶嵌）必须 DISABLED + 原因，不崩。
	# 【2026-10-09】voronoi 已登记（(p) 段）⇒ 从本反例名单移出，改用仍未登记的近似名。
	for bad in ["circle_wrap", "star6", "sectorize", "hyperbolic", "union"]:
		assert_eq(M.status("classic", bad), M.DISABLED, "未登记族 %s 应 DISABLED" % bad)
		assert_ne(M.reason("classic", bad).strip_edges(), "", "未登记族 %s 应给原因" % bad)


# ==================== C. UI：下拉能选到 + 写对文档 + 盘重建 + 闸门拦超预算 ====================

func test_shape_dropdown_selects_outline_families() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(9, 9)
	ed.doc = d
	ed.call("_doc_to_ui")
	var opt := ed.get("_shape_opt") as OptionButton
	var sb := ed.get("_shape_size") as SpinBox
	assert_not_null(opt, "应有形状下拉")
	assert_not_null(sb, "应有形状尺寸控件")
	assert_eq(opt.item_count, 8, "形状下拉应含 方阵/六边形/三角/圆/星/扇/Voronoi/等轴菱面 八项")
	# 索引 → (kind, 尺寸参数名)
	# 【2026-10-09】+ (p) Voronoi：它的「形状尺寸」= 种子数（2 个以上），故 key 是 "sites" 而非半径。
	# 【2026-10-09】+ (q) 等轴菱面：它的「形状尺寸」= 方块域边长，key 是 "cols"（rows 同值）。
	var cases: Array = [[3, "circle", "radius"], [4, "star", "outer_radius"], [5, "sector", "radius"],
			[6, "voronoi", "sites"], [7, "iso_cubes", "cols"]]
	for c: Variant in cases:
		var idx := int(c[0])
		var kind := str(c[1])
		var key := str(c[2])
		opt.selected = idx
		sb.value = 4
		ed.call("_on_shape_selected")
		assert_eq(d.shape_kind, kind, "选第 %d 项应写入 doc.shape_kind=%s" % [idx, kind])
		assert_eq(int(d.shape_params.get(key, -1)), 4,
				"%s：shape_params.%s 默认值应为 4（收到 %s）" % [kind, key, str(d.shape_params)])
		var g: GridInterface = d.grid()
		assert_not_null(g, "%s：切换后棋盘必须按新形状重建" % kind)
		assert_gt(g.cell_count(), 0, "%s：重建的盘应有格" % kind)
		var ag := g as AdjacencyGrid
		assert_not_null(ag, "%s：形状盘应是 AdjacencyGrid" % kind)
		assert_eq(ag.style, kind, "%s：风格应随盘贯通（渲染 / 落盘依赖）" % kind)
		assert_eq(opt.selected, idx, "%s：下拉选中项应与文档一致（_doc_to_ui 回写）" % kind)
	# 非半径的默认参数也要合理且被写入。
	opt.selected = 4
	sb.value = 4
	ed.call("_on_shape_selected")
	assert_eq(int(d.shape_params.get("points", -1)), 5, "星形默认 5 角")
	assert_almost_eq(float(d.shape_params.get("inner_ratio", -1.0)), 0.5, 0.0001,
			"星形默认内/外半径比 0.5")
	opt.selected = 5
	sb.value = 4
	ed.call("_on_shape_selected")
	assert_almost_eq(float(d.shape_params.get("start_deg", -1.0)), 0.0, 0.0001, "扇形默认 start=0°")
	assert_almost_eq(float(d.shape_params.get("end_deg", -1.0)), 90.0, 0.0001, "扇形默认 end=90°")


## (q) 等轴菱面：语义与既有族**不同**的地方要单独钉住，免得以后被"统一"掉。
func test_iso_cubes_shape_writes_square_cube_domain() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(9, 9)
	ed.doc = d
	ed.call("_doc_to_ui")
	var opt := ed.get("_shape_opt") as OptionButton
	var sb := ed.get("_shape_size") as SpinBox
	opt.selected = 7
	sb.value = 3
	ed.call("_on_shape_selected")
	assert_eq(d.shape_kind, "iso_cubes", "第 8 项应写入 iso_cubes")
	assert_eq(int(d.shape_params.get("cols", -1)), 3, "「形状尺寸」应写成方块域 cols")
	assert_eq(int(d.shape_params.get("rows", -1)), 3, "「形状尺寸」应写成方块域 rows（正方形域）")
	assert_eq(d.shape_params.get("holes", null), [], "编辑器入口只产实心方块阵列（洞留给离线生成器）")
	# 盘面 = 3n × n，格数 = 3n²（每方块 3 个面）——与 build_iso_cubes 同口径。
	var g := d.grid() as AdjacencyGrid
	assert_not_null(g, "iso_cubes 应能建出 AdjacencyGrid")
	assert_eq(g.cell_count(), 27, "3×3 个方块 = 27 格（每方块 3 个面）")
	var sz := AdjacencyGrid.normalized(g).size()
	assert_eq(Vector2i(sz.x, sz.y), Vector2i(9, 3), "盘面包围盒应为 3n × n")
	assert_eq(Vector2i(d.cols, d.rows), Vector2i(9, 3), "doc 的 size 必须同步成包围盒（否则雷位会判越界）")
	# 回填：打开这样一份关卡，下拉与尺寸控件要对得上。
	d.cols = 9
	d.rows = 3
	ed.call("_doc_to_ui")
	assert_eq(opt.selected, 7, "回读后下拉应指回等轴菱面")
	assert_eq(int(sb.value), 3, "回读后「形状尺寸」应取 cols（3），不是包围盒宽度（9）")


## (q) 等轴菱面的结构硬上限：盘面 3n² 格必须在 MAX_CELLS 以内，
## 40×40 的方块域 = 120×40 = 4800 格 > 4096 ⇒ 必须被闸门拦住、不动文档（而不是"能编辑、不能玩"）。
func test_iso_cubes_blocks_over_bbox_request() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(9, 9)
	ed.doc = d
	ed.call("_doc_to_ui")
	var opt := ed.get("_shape_opt") as OptionButton
	var sb := ed.get("_shape_size") as SpinBox
	# 先验闸门本身（便宜上界 + 精确包围盒两道取更严）。
	var over: Dictionary = {"cols": 40, "rows": 40, "holes": []}
	assert_false(bool(ed.call("_budget_allows", "iso_cubes", over, 40, 40)),
			"40×40 方块域（120×40=4800 格）应超结构硬上限")
	assert_true(bool(ed.call("_budget_allows", "iso_cubes", {"cols": 36, "rows": 36, "holes": []}, 36, 36)),
			"36×36 方块域（108×36=3888 格）应放行")
	# 走真实路径：把尺寸控件放开上限后设为 40，选等轴菱面 ⇒ 文档不得被改动（下拉被拉回）。
	opt.selected = 7
	sb.allow_greater = true
	sb.value = 40
	ed.call("_on_shape_selected")
	assert_eq(d.shape_kind, "", "超上限选择必须被闸门拦住：doc.shape_kind 不得改动")
	assert_eq(d.shape_params, {}, "超上限选择必须被闸门拦住：doc.shape_params 不得写入")
	assert_eq(opt.selected, 0, "被拦后下拉应被拉回文档当前值（方阵）")


func test_shape_dropdown_blocks_over_budget_request() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(9, 9)
	ed.doc = d
	ed.call("_doc_to_ui")
	var opt := ed.get("_shape_opt") as OptionButton
	var sb := ed.get("_shape_size") as SpinBox
	# 直接验闸门本身：半径 60 的轮廓盘上界远超 EditorDoc.MAX_CELL_BUDGET。
	var reason := EditorDoc.check_cell_budget(EditorDoc.estimate_cells(
			"circle", {"radius": 60, "precision": 24}, 121, 121))
	assert_false(bool(reason["ok"]), "半径 60 的圆应超硬上限（estimate=%s）" % str(reason))
	assert_false(bool(ed.call("_budget_allows", "circle", {"radius": 60, "precision": 24}, 121, 121)),
			"既有预算闸门必须拦住超上限的圆")
	# 走真实路径：把尺寸控件放开上限后设为 60，选圆 ⇒ 文档不得被改动（下拉被拉回）。
	opt.selected = 3
	sb.allow_greater = true
	sb.value = 60
	ed.call("_on_shape_selected")
	assert_eq(d.shape_kind, "", "超预算选择必须被闸门拦住：doc.shape_kind 不得改动")
	assert_eq(d.shape_params, {}, "超预算选择必须被闸门拦住：doc.shape_params 不得写入")
	assert_eq(opt.selected, 0, "被拦后下拉应被拉回文档当前值（方阵）")
# ==================== D. 任务取消 / 去抖（文档 §G4「任务取消机制」/ §G6） ====================
#
# 场景：用户连续拖「形状尺寸」滑杆。若每个 `value_changed` 都跑一次全盘重栅格化，盘一大
# 就会把拖动拖成灾难（code.md §G4 原话）。契约：
#   · 拖动只登记去抖待办，**不逐 tick 重算**；
#   · 到期由 `_process` 合并成**一次**重算（连拖若干次只留最后一个值 = 取消旧任务）；
#   · 离散换族（下拉）立即生效并清空待办（= 取消排队中未开始的旧任务）。

func _shape_due_ms(ed: Object) -> int:
	return int(ed.get("_shape_change_due"))


func test_shape_size_drag_is_debounced_not_applied_per_tick() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(9, 9)
	ed.doc = d
	ed.call("_doc_to_ui")
	var opt := ed.get("_shape_opt") as OptionButton
	var sb := ed.get("_shape_size") as SpinBox
	opt.selected = 3                       # 圆
	sb.value = 5                           # 模拟拖动滑杆（不是离散选择）
	assert_gt(_shape_due_ms(ed), 0, "拖滑杆应登记去抖待办，而不是立刻重算")
	assert_eq(d.shape_kind, "", "拖动过程中不得逐 tick 直接重建盘（文档 §G4）")
	# 把待办拨到过去 ⇒ 模拟去抖窗口走完，由 `_process` 合并执行一次。
	ed.set("_shape_change_due", 1)
	ed.call("_process", 0.016)
	assert_eq(d.shape_kind, "circle", "去抖到期后应真的换形状")
	assert_eq(int(d.shape_params.get("radius", -1)), 5, "应写入最后读到的尺寸")
	assert_eq(_shape_due_ms(ed), 0, "消费后待办必须清零（否则每帧重复重算）")


func test_shape_size_drag_coalesces_to_last_value() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(9, 9)
	ed.doc = d
	ed.call("_doc_to_ui")
	var opt := ed.get("_shape_opt") as OptionButton
	var sb := ed.get("_shape_size") as SpinBox
	opt.selected = 3
	sb.value = 6
	sb.value = 7
	sb.value = 8
	ed.set("_shape_change_due", 1)
	ed.call("_process", 0.016)
	assert_eq(int(d.shape_params.get("radius", -1)), 8,
			"连续拖动只保留最后一个值：排队中未开始的旧任务必须被取消（文档 §G4）")


func test_shape_kind_switch_cancels_pending_size_task() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(9, 9)
	ed.doc = d
	ed.call("_doc_to_ui")
	var opt := ed.get("_shape_opt") as OptionButton
	var sb := ed.get("_shape_size") as SpinBox
	opt.selected = 3
	sb.value = 5
	assert_gt(_shape_due_ms(ed), 0, "先拖滑杆 ⇒ 应有排队中未开始的待办")
	opt.selected = 4                       # 星形（下拉 item_selected 的落点）
	ed.call("_on_shape_selected")
	assert_eq(d.shape_kind, "star", "离散换族必须立即生效")
	assert_eq(_shape_due_ms(ed), 0, "立即执行必须取消排队中未开始的旧任务")
	# 再走一遍 `_process`：旧任务若没被取消，会把形状补写成圆。
	ed.call("_process", 0.016)
	assert_eq(d.shape_kind, "star", "旧任务不许在新选择之后补跑")
