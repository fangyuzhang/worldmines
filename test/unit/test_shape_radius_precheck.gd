extends GutTest

## 轮廓三族（圆 / 星 / 扇）在 UI 侧的**半径上界预检**（两道闸门取更严）。
##
## 实测确认的两堵墙（都只在 core 侧，本文件不改 core）：
##   A. `ShapeGenerator.build_circle/build_star/build_sector` 建盘前用闭式上界 `π(r+1)²+1`
##      （扇再乘张角比）挡 `EditorDoc.MAX_CELL_BUDGET`（5000）；超了**直接返回 0 格**（盘会变空）。
##      而 `EditorDoc.estimate_cells` 给的是精确几何格数 ⇒ 圆 r=39 分叉（精确 4718 放行 / 上界 5027 拒收）。
##   B. `EditorDoc.validate()` / `LevelGuard` 用 `rows*cols > MAX_CELLS(4096)` 硬拒；形状盘的 rows*cols
##      = **包围盒面积**（圆 r=33 → 65×66=4290）⇒ "能编辑、不能玩"，重导入还会被加载器拒收。
## 预检必须两道取更严，并只给**一个**可用上限数字，否则用户会在两堵墙之间被来回弹。
##
## 本文件钉住：
##   1) 两堵墙都真实存在（先用生成器/estimate/validate 取证，防"修了个不存在的问题"）；
##   2) 上限内 ⇒ 放行且盘真能重建；
##   3) 超上限 ⇒ 被 `_budget_allows` 拦住、提示非空（含当前半径 + 可用上限 + 后果）、
##      `doc.shape_kind/shape_params` **未被改写**（无半成品态）；
##   4) **真实 UI 路径**（`_shape_size` 上限已抬到 40 ⇒ 半径 39 在控件范围内）确实触发拦截；
##   5) 报给用户的可用上限 = 生成器产格 且 包围盒 ≤ 4096 的**真实**最大半径。

## 三族：下拉索引 / kind / 半径参数名 / 真实可建上限 / 生成器闸门越界值 / 结构闸门越界值 / 其余默认参数。
const CASES: Array = [
	{"idx": 3, "kind": "circle", "key": "radius", "max": 32, "gen_over": 39, "struct_over": 33,
		"defaults": {"precision": 24}},
	{"idx": 4, "kind": "star", "key": "outer_radius", "max": 35, "gen_over": 39, "struct_over": 36,
		"defaults": {"points": 5, "inner_ratio": 0.5}},
	{"idx": 5, "kind": "sector", "key": "radius", "max": 63, "gen_over": 79, "struct_over": 64,
		"defaults": {"start_deg": 0.0, "end_deg": 90.0}},
]


# ==================== 工具 ====================

func _make_editor() -> Object:
	var scene: PackedScene = load("res://ui/level_editor.tscn")
	assert_not_null(scene, "编辑器场景应能加载")
	# 编辑器脚本没有 class_name ⇒ 一律声明成 Object 并用 .call()（沿用仓内既有测试约定）。
	var ed: Object = scene.instantiate()
	add_child_autofree(ed as Node)
	return ed


func _params_for(c: Dictionary, radius: int) -> Dictionary:
	var p: Dictionary = (c["defaults"] as Dictionary).duplicate()
	p[str(c["key"])] = radius
	return p


## 直接问生成器"这一族这个半径真出多少格"——不经任何 UI/估算层，作独立对照。
func _direct_cells(c: Dictionary, radius: int) -> int:
	var p := _params_for(c, radius)
	match str(c["kind"]):
		"circle":
			return (ShapeGenerator.build_circle(radius, int(p["precision"]))["positions"] as Array).size()
		"star":
			return (ShapeGenerator.build_star(int(p["points"]), radius,
					float(p["inner_ratio"]))["positions"] as Array).size()
		"sector":
			return (ShapeGenerator.build_sector(radius, float(p["start_deg"]),
					float(p["end_deg"]))["positions"] as Array).size()
	return 0


## 走文档自己的口径取"形状盘真实 rows×cols"（= `sync_size_to_shape` + validate 用的那个）。
func _doc_shape_rc(c: Dictionary, radius: int) -> Vector2i:
	var d := EditorDoc.new(9, 9)
	d.shape_kind = str(c["kind"])
	d.shape_params = _params_for(c, radius)
	d.sync_size_to_shape()
	return Vector2i(d.cols, d.rows)


# ==================== 1. 两堵墙都真实存在 ====================

func test_generator_wall_is_real_at_radius_39() -> void:
	# 圆 r=39：estimate 精确 4718（≤5000，放行）；生成器上界 5027（>5000，拒收）⇒ 返回 0 格。
	var est := EditorDoc.estimate_cells("circle", {"radius": 39, "precision": 24}, 0, 0)
	assert_true(bool(EditorDoc.check_cell_budget(est)["ok"]),
			"estimate 在 r=39 应放行（est=%d）——否则本缺口不成立" % est)
	assert_false(bool(EditorDoc.check_cell_budget(
			int(ShapeGenerator._disk_upper_bound(39.0)))["ok"]),
			"生成器上界在 r=39 应超 MAX_CELL_BUDGET")
	assert_true((ShapeGenerator.build_circle(39, 24)["positions"] as Array).is_empty(),
			"生成器在 r=39 确实返回 0 格（这就是「界面放行则会变空盘」的机理）")


func test_structural_wall_4096_is_real_and_stricter_than_budget() -> void:
	# 圆 r=33：生成器照样产格（3382 格 ≤ 5000），但包围盒 65×66=4290 > 4096 ⇒ validate 报"格数超限"。
	var cells := _direct_cells(CASES[0], 33)
	assert_gt(cells, 0, "圆 r=33 生成器应照样产格（所以 estimate/生成器两关都拦不住它）")
	var rc := _doc_shape_rc(CASES[0], 33)
	assert_gt(rc.x * rc.y, EditorDoc.MAX_CELLS,
			"圆 r=33 的包围盒 %d×%d 应超结构硬上限 %d" % [rc.x, rc.y, EditorDoc.MAX_CELLS])
	var d := EditorDoc.new(9, 9)
	d.shape_kind = "circle"
	d.shape_params = {"radius": 33, "precision": 24}
	d.sync_size_to_shape()
	var over_msg := ""
	for it in d.validate()["errors"]:
		if str((it as Dictionary)["text"]).find(str(EditorDoc.MAX_CELLS)) != -1:
			over_msg = str((it as Dictionary)["text"])
	assert_ne(over_msg, "", "validate() 必须就 4096 给出可读错误（能编辑、不能玩的那堵墙）")


# ==================== 2. 上限内：放行 + 盘能重建 ====================

func test_within_limit_allows_and_rebuilds_board_all_three_families() -> void:
	var ed := _make_editor()
	for c: Dictionary in CASES:
		var kind := str(c["kind"])
		var d := EditorDoc.new(9, 9)
		ed.doc = d
		ed.call("_doc_to_ui")
		var opt := ed.get("_shape_opt") as OptionButton
		var sb := ed.get("_shape_size") as SpinBox
		opt.selected = int(c["idx"])
		sb.value = 5.0                       # 小半径：盘能真重建且不拖慢用例
		ed.call("_on_shape_selected")
		assert_eq(d.shape_kind, kind, "%s：上限内选择应写入 shape_kind" % kind)
		assert_eq(int(d.shape_params.get(str(c["key"]), -1)), 5,
				"%s：shape_params.%s 应写入 5" % [kind, str(c["key"])])
		var g: GridInterface = d.grid()
		assert_not_null(g, "%s：上限内必须重建出盘" % kind)
		assert_gt(g.cell_count(), 0, "%s：重建的盘应有格" % kind)
		assert_eq((g as AdjacencyGrid).style, kind, "%s：风格应随盘贯通" % kind)
		# 真实上限处必须放行；报给用户的上限也必须等于它。
		var rmax := int(c["max"])
		assert_eq(int(ed.call("_max_usable_shape_radius", kind, _params_for(c, rmax))), rmax,
				"%s：报给用户的可用上限应= %d" % [kind, rmax])
		assert_eq(str(ed.call("_shape_upper_bound_reason", kind, _params_for(c, rmax))), "",
				"%s：r=%d（上限）预检应放行" % [kind, rmax])


# ==================== 3. 超上限：拦住 + 提示非空 + 不动文档 ====================

func test_over_limit_blocks_with_hint_all_three_families() -> void:
	var ed := _make_editor()
	for c: Dictionary in CASES:
		var kind := str(c["kind"])
		var rmax := int(c["max"])
		for r_off: int in [int(c["gen_over"]), int(c["struct_over"])]:
			var bad := _params_for(c, r_off)
			var reason := str(ed.call("_shape_upper_bound_reason", kind, bad))
			assert_ne(reason.strip_edges(), "", "%s：r=%d 应给非空提示" % [kind, r_off])
			assert_true(reason.find(str(r_off)) != -1,
					"%s：提示应说清当前半径 %d（收到：%s）" % [kind, r_off, reason])
			assert_true(reason.find(str(rmax)) != -1,
					"%s：提示应给出可用上限 %d（收到：%s）" % [kind, rmax, reason])
			assert_true(reason.find("变空") != -1 or reason.find("上限") != -1,
					"%s：提示应说清后果（变空 / 超限）" % kind)
			assert_false(bool(ed.call("_budget_allows", kind, bad, 121, 121)),
					"%s：r=%d 必须被闸门拦住" % [kind, r_off])
		# 生成器闸门越界值确实会被生成器 0 格；结构闸门越界值确实超 4096。
		assert_eq(_direct_cells(c, int(c["gen_over"])), 0,
				"%s：r=%d 生成器应返回 0 格" % [kind, int(c["gen_over"])])
		var rc := _doc_shape_rc(c, int(c["struct_over"]))
		assert_gt(rc.x * rc.y, EditorDoc.MAX_CELLS,
				"%s：r=%d 包围盒应超 4096" % [kind, int(c["struct_over"])])


# ==================== 4. 真实 UI 路径：尺寸上限 40 ⇒ 半径 39 可触发拦截 ====================

func test_radius_39_blocks_through_real_ui_path_without_touching_doc() -> void:
	# 尺寸控件上限已抬到 40 ⇒ 39 是**用户真能在界面上调到的值**（不需要 allow_greater 之类的测试手法）。
	var ed := _make_editor()
	# 圆：39 撞生成器闸门；33 撞结构闸门 —— 两条都必须在真实 UI 路径上被拦、且文档分毫不动。
	for case_and_r: Array in [[3, "circle", 39], [3, "circle", 33], [4, "star", 39], [4, "star", 36]]:
		var idx := int(case_and_r[0])
		var kind := str(case_and_r[1])
		var r := int(case_and_r[2])
		var d := EditorDoc.new(9, 9)
		d.mines.append(Vector2i(0, 0))
		ed.doc = d
		ed.call("_doc_to_ui")
		var opt := ed.get("_shape_opt") as OptionButton
		var sb := ed.get("_shape_size") as SpinBox
		assert_true(r <= int(sb.max_value), "r=%d 应落在控件范围内（上限 %d）" % [r, int(sb.max_value)])
		# 先拨尺寸（此刻下拉仍是文档当前值=方阵，任何前置回调都只是无害的方阵重建），再选形状。
		sb.value = float(r)                  # 真实信号：value_changed → _on_shape_selected
		opt.selected = idx
		ed.call("_on_shape_selected")
		assert_eq(d.shape_kind, "", "%s r=%d：被拦后 doc.shape_kind 不得改写" % [kind, r])
		assert_eq(d.shape_params, {}, "%s r=%d：被拦后 doc.shape_params 不得写入" % [kind, r])
		assert_eq(d.rows, 9, "%s r=%d：被拦后盘尺寸不得变" % [kind, r])
		assert_true(d.mines.has(Vector2i(0, 0)), "%s r=%d：原有雷位不得丢" % [kind, r])
		assert_eq(opt.selected, 0, "%s r=%d：被拦后下拉应被拉回（方阵）" % [kind, r])


func test_sector_in_ui_range_is_not_over_blocked() -> void:
	# 扇形的结构上限是 63 > 控件上限 40 ⇒ 控件内所有半径都必须放行（防"误拦合法盘"）。
	var ed := _make_editor()
	var d := EditorDoc.new(9, 9)
	ed.doc = d
	ed.call("_doc_to_ui")
	var opt := ed.get("_shape_opt") as OptionButton
	var sb := ed.get("_shape_size") as SpinBox
	opt.selected = 5
	sb.value = 40.0
	ed.call("_on_shape_selected")
	assert_eq(d.shape_kind, "sector", "扇形 r=40（控件上限）必须放行")
	assert_eq(int(d.shape_params.get("radius", -1)), 40, "扇形 r=40 应写入参数")
	assert_gt(d.grid().cell_count(), 0, "扇形 r=40 的盘必须有格")


# ==================== 5. 报给用户的上限 = 生成器产格 且 ≤4096 ====================

func test_reported_max_radius_is_the_real_buildable_limit() -> void:
	var ed := _make_editor()
	for c: Dictionary in CASES:
		var kind := str(c["kind"])
		var rmax := int(c["max"])
		var at_max := _params_for(c, rmax)
		assert_eq(int(ed.call("_max_usable_shape_radius", kind, at_max)), rmax,
				"%s：报给用户的可用上限应与真实可建上限一致" % kind)
		# 上限处：生成器有格 + 包围盒 ≤ 4096（不是靠某一堵墙勉强放行）。
		assert_gt(_direct_cells(c, rmax), 0, "%s：r=%d 生成器应有格" % [kind, rmax])
		var rc := _doc_shape_rc(c, rmax)
		assert_true(rc.x * rc.y <= EditorDoc.MAX_CELLS,
				"%s：r=%d 包围盒 %d×%d 应在 4096 内" % [kind, rmax, rc.x, rc.y])
		assert_eq(str(ed.call("_shape_upper_bound_reason", kind, at_max)), "",
				"%s：r=%d（上限）预检应放行" % [kind, rmax])
		# 上限 +1 必须被拒（上界函数与生成器/结构两堵墙都对齐）。
		assert_ne(str(ed.call("_shape_upper_bound_reason", kind, _params_for(c, rmax + 1))), "",
				"%s：r=%d 必须被拒" % [kind, rmax + 1])
