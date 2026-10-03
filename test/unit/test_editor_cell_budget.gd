extends GutTest

## 编辑器格子数双档预算（文档 A 项）：**操作前**估算 + 硬阻。
##
## 钉住的不变量（坏一条，用户就会"等半天才被告知盘太大"或"被毫无理由地拦住"）：
##   1) 纯函数 `estimate_cells` 与 `ShapeGenerator` 真建出来的盘**逐族格数一致**（防两条公式漂移）；
##   2) 档位正确：≤ 预算 ok、> 预算且 ≤ 最高 warn、> 最高 block（`block` 时 `ok=false`）；
##   3) `block` 时 UI 路径**不执行**：文档 rows/cols/格集一律不变（走真实控件信号触发）。


# ==================== 1. 估算 == 真实格数 ====================

func test_estimate_matches_real_shapes() -> void:
	# 少算 ⇒ 漏拦大盘；多算 ⇒ 误拦合法盘。两种都是 bug，所以逐族对照真网格。
	for p in [{"size": 4}, {"size": 7}]:
		assert_eq(EditorDoc.estimate_cells("hex", p, 0, 0),
			ShapeGenerator.to_adjacency_grid("hex", p).all_positions().size(),
			"hex 估算应与真实格数一致：%s" % str(p))
	for p2 in [{"cols": 5, "rows": 3}, {"cols": 4, "rows": 4}]:
		assert_eq(EditorDoc.estimate_cells("tri_grid", p2, 0, 0),
			ShapeGenerator.to_adjacency_grid("tri_grid", p2).all_positions().size(),
			"tri_grid 估算应与真实格数一致：%s" % str(p2))
	for p3 in [{"size": 3}, {"size": 5}]:
		assert_eq(EditorDoc.estimate_cells("t488", p3, 0, 0),
			ShapeGenerator.to_adjacency_grid("t488", p3).all_positions().size(),
			"t488 估算应与真实格数一致：%s" % str(p3))
	var ring := {"sectors": [6, 12, 18]}
	assert_eq(EditorDoc.estimate_cells("ring", ring, 0, 0),
		ShapeGenerator.to_adjacency_grid("ring", ring).all_positions().size(), "ring 估算应一致")
	var holed := {"rows": 6, "cols": 6, "holes": [{"x": 0, "y": 0}, {"x": 1, "y": 1}]}
	assert_eq(EditorDoc.estimate_cells("holed_grid", holed, 0, 0),
		ShapeGenerator.to_adjacency_grid("holed_grid", holed).all_positions().size(), "holed_grid 估算应一致")


func test_estimate_square_and_doc_helper() -> void:
	var d := EditorDoc.new(9, 9)
	assert_eq(d.estimate_cells_now(), 81, "方阵按 rows*cols 估算")
	assert_eq(int(d.cell_budget_report()["estimate"]), 81)
	assert_eq(str(d.cell_budget_report()["level"]), "ok")
	# 形状盘按**几何族**估算，而不是包围盒（build_hex(size=4) 实际是 10 格，既不是 4x4=16 也不是 bbox）
	d.shape_kind = "hex"
	d.shape_params = {"size": 4}
	assert_eq(d.estimate_cells_now(), 10, "形状盘必须按几何族估算")


# ==================== 2. 档位边界 ====================

func test_budget_levels_ok_warn_block() -> void:
	# ① 小盘 9x9=81 ≤ 500 ⇒ ok
	var ok := EditorDoc.check_cell_budget(81)
	assert_eq(str(ok["level"]), "ok")
	assert_true(bool(ok["ok"]))
	assert_eq((ok["hints"] as Array).size(), 3, "任何档位都要给三条出路")
	# ② 超预算但 ≤ 最高：30x30=900 ⇒ warn（仍允许执行）
	var warn := EditorDoc.check_cell_budget(900)
	assert_eq(str(warn["level"]), "warn")
	assert_true(bool(warn["ok"]), "warn 档必须仍允许执行（提示而非阻断）")
	assert_true(str(warn["reason"]).find("900") != -1, "提示里要写清预计格数")
	# 恰好等于预算 ⇒ ok；预算 +1 ⇒ warn（把边界写死）
	assert_eq(str(EditorDoc.check_cell_budget(EditorDoc.DEFAULT_CELL_BUDGET)["level"]), "ok")
	assert_eq(str(EditorDoc.check_cell_budget(EditorDoc.DEFAULT_CELL_BUDGET + 1)["level"]), "warn")
	# ③ 超最高值 5000 ⇒ block
	var blk := EditorDoc.check_cell_budget(EditorDoc.MAX_CELL_BUDGET + 1)
	assert_eq(str(blk["level"]), "block")
	assert_false(bool(blk["ok"]), "block 档必须 ok=false，调用方据此不执行")
	assert_eq((blk["hints"] as Array).size(), 3, "block 也要给三条出路")
	# 恰好等于最高值 5000 ⇒ 不是 block（门槛是 > 最高值）
	assert_ne(str(EditorDoc.check_cell_budget(EditorDoc.MAX_CELL_BUDGET)["level"]), "block")


# ==================== 3. UI 路径：block 时不动文档 ====================

func _make_editor() -> Object:
	var scene: PackedScene = load("res://ui/level_editor.tscn")
	assert_not_null(scene, "编辑器场景应能加载")
	# 编辑器脚本没有 class_name ⇒ 一律声明成 Object 并用 .call()（否则静态检查编译失败）
	var ed: Object = scene.instantiate()
	add_child_autofree(ed as Node)
	return ed


func test_blocked_size_change_leaves_document_untouched() -> void:
	# 走真实控件信号：把行 SpinBox 上限临时抬高，设一个 rows*cols 超最高上限的值 ⇒ 应被硬阻。
	var ed := _make_editor()
	var d := EditorDoc.new(9, 9)
	d.mines.append(Vector2i(0, 0))
	d.revealed[Vector2i(8, 8)] = null
	ed.doc = d
	ed.call("_doc_to_ui")
	var rows_spin := ed.get("_rows_spin") as SpinBox
	rows_spin.max_value = 1000.0
	rows_spin.value = 700.0            # 700 × 9 = 6300 > 5000 ⇒ block
	assert_eq(d.rows, 9, "被硬阻的尺寸改动不得写进文档")
	assert_eq(d.cols, 9, "列也不应变")
	assert_eq(d.mines.size(), 1, "格集（雷）不得变")
	assert_true(d.mines.has(Vector2i(0, 0)), "原有的雷必须还在")
	assert_true(d.revealed.has(Vector2i(8, 8)), "初始翻开格也不得变")
	assert_eq(int(rows_spin.value), 9, "界面控件应被拉回文档值，避免显示一个没生效的尺寸")


func test_normal_size_change_still_applies() -> void:
	# 反向守卫：闸门不能误拦正常改动。
	var ed := _make_editor()
	var d := EditorDoc.new(9, 9)
	ed.doc = d
	ed.call("_doc_to_ui")
	(ed.get("_rows_spin") as SpinBox).value = 16.0   # 16 × 9 = 144 ≤ 500
	assert_eq(d.rows, 16, "正常尺寸改动应照常生效")


func test_random_mines_blocked_on_oversize_doc() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(80, 80)     # 6400 > 5000
	d.mines.append(Vector2i(1, 1))
	ed.doc = d
	ed.call("_doc_to_ui")
	(ed.get("_mines_spin") as SpinBox).value = 5.0
	ed.call("_random_mines")
	assert_eq(d.mines.size(), 1, "超上限盘上随机布雷必须被硬阻，格集不变")
	assert_true(d.mines.has(Vector2i(1, 1)), "原有雷位必须保持不变")
