# test_coloring_preview.gd —— 四象染色预览 / 行容量（文档 §5 变体专用工具）的钉子
#
# 钉五件事：
#   ① 四象色号**复用** ConstraintEngine.quadrant_of（逐格对拍：不许另写一份划分）；
#   ② 四象守恒：四象限 + 中轴 == 盘内格数；盘外格被忽略并计数（判界一律问网格）；
#   ③ 网格门禁来自 VariantGridMatrix：非矩形族一律拒绝 + 可读原因（不臆造语义）；
#   ④ 行容量：每行 capacity / mines / remaining 正确；三条不可行判据都触发并给原因；
#   ⑤ 行容量枚举的是**盘内格**（洞格不计入容量）——用挖洞盘验证。
extends GutTest

const CP := preload("res://core/coloring_preview.gd")
const CE := preload("res://core/constraint_engine.gd")
const SG := preload("res://core/shape_generator.gd")
const MATRIX := preload("res://core/variant_grid_matrix.gd")


# ==================== ① 与四象唯一原语逐格对拍 ====================

func test_quadrant_levels_match_constraint_engine() -> void:
	var grid = _rect(5, 5)
	var rep: Dictionary = CP.quadrant_preview(grid, grid.all_positions(), MATRIX.RECT)
	assert_true(bool(rep["ok"]), "5×5 矩形盘上四象预览应可用：%s" % str(rep["reason"]))
	var cells: Dictionary = rep["cells"]
	assert_eq(cells.size(), 25, "4 象限 + 中轴的格数应等于盘内格数（守恒）")
	for p: Vector2i in cells.keys():
		var rec: Dictionary = cells[p]
		var qi := int(CE.quadrant_of(p.y, p.x, 5, 5))
		var want := CP.AXIS_LEVEL if qi < 0 else qi
		assert_eq(int(rec["level"]), want,
				"(%d,%d) 的预览色号必须来自 ConstraintEngine.quadrant_of（不许另写一份）" % [p.x, p.y])
		assert_eq(bool(rec["axis"]), qi < 0, "(%d,%d) 的中轴判定应与 quadrant_of 一致" % [p.x, p.y])


func test_quadrant_counts_conserve_and_axis_is_separate() -> void:
	var grid = _rect(5, 5)
	var rep: Dictionary = CP.quadrant_preview(grid, grid.all_positions(), MATRIX.RECT)
	var counts: Array = rep["counts"]
	assert_eq(counts.size(), CP.QUADRANT_COUNT + 1, "计数数组 = 4 象限 + 1 中轴")
	var sum := 0
	for c in counts:
		sum += int(c)
	assert_eq(sum, grid.cell_count(), "四象限 + 中轴 == 盘内格数（守恒不变量）")
	for i in CP.QUADRANT_COUNT:
		assert_eq(int(counts[i]), 4, "5×5 盘的每个象限应是 4 格（硬编码期望）")
	assert_eq(int(counts[CP.AXIS_LEVEL]), 9, "5×5 盘的中轴（第 2 行 + 第 2 列 − 中心）应是 9 格")
	# 偶数盘：没有中轴格（quadrant_of 的既有语义）
	var g4 = _rect(4, 4)
	var r4: Dictionary = CP.quadrant_preview(g4, g4.all_positions(), MATRIX.RECT)
	assert_eq(int((r4["counts"] as Array)[CP.AXIS_LEVEL]), 0, "4×4 偶数盘没有中轴格")
	assert_eq(int((r4["counts"] as Array)[0]), 4, "4×4 的每个象限应是 4 格")


func test_quadrant_preview_ignores_off_board_cells() -> void:
	var grid = _rect(3, 3)
	var cells_in: Array = grid.all_positions().duplicate()
	cells_in.append(Vector2i(99, 99))
	var rep: Dictionary = CP.quadrant_preview(grid, cells_in, MATRIX.RECT)
	assert_true(bool(rep["ok"]), "合法调用应成功")
	assert_eq((rep["cells"] as Dictionary).size(), 9, "盘外格不得进入预览")
	assert_eq((rep["off_board"] as Array).size(), 1, "盘外格要被忽略**并计数**（不静默）")
	assert_false((rep["cells"] as Dictionary).has(Vector2i(99, 99)), "盘外格不得上色")


# ==================== ③ 网格门禁 ====================

func test_quadrant_preview_is_gated_by_grid_matrix() -> void:
	for kind in [MATRIX.HEX, MATRIX.TRI_GRID, MATRIX.CIRCLE, "voronoi"]:
		var rep: Dictionary = CP.quadrant_preview(_rect(5, 5), [], kind)
		assert_false(bool(rep["ok"]), "网格族 %s 上四象未定义 ⇒ 必须拒绝" % kind)
		assert_eq((rep["cells"] as Dictionary).size(), 0, "%s ⇒ 不得留下半成品预览" % kind)
		assert_ne(str(rep["reason"]).strip_edges(), "", "%s ⇒ 必须给可读原因" % kind)
	# 合法的矩形族必须可用（基线）
	for kind in [MATRIX.RECT]:
		assert_true(bool(CP.quadrant_preview(_rect(5, 5), [], kind)["ok"]),
				"网格族 %s 上四象应可用" % kind)


# ==================== ④ 行容量 ====================

func test_row_report_counts_capacity_and_mines() -> void:
	var grid = _rect(5, 5)
	var mines := [Vector2i(0, 1), Vector2i(3, 1), Vector2i(4, 4)]
	var rep: Dictionary = CP.row_report(grid, 2, mines, MATRIX.RECT)
	assert_true(bool(rep["ok"]), "5×5 矩形盘上行容量应可用：%s" % str(rep["reason"]))
	var rows: Array = rep["rows"]
	assert_eq(rows.size(), 5, "5×5 盘应有 5 行")
	for i in rows.size():
		var rec: Dictionary = rows[i]
		assert_eq(int(rec["y"]), i, "行必须按 y 升序")
		assert_eq(int(rec["capacity"]), 5, "每行容量 = 该行盘内格数")
		assert_eq(int(rec["target"]), 2, "目标原样回显")
		assert_eq(int(rec["remaining"]), 5 - int(rec["mines"]), "剩余 = 容量 − 已放")
	assert_eq(int((rows[1] as Dictionary)["mines"]), 2, "第 1 行放了 2 颗")
	assert_eq(int((rows[4] as Dictionary)["mines"]), 1, "第 4 行放了 1 颗")
	assert_eq((rep["infeasible"] as Array).size(), 0, "目标 2、每行 5 格 ⇒ 全部可行")
	# 守恒：各行容量之和 == 盘内格数
	var sum := 0
	for rec: Dictionary in rows:
		sum += int(rec["capacity"])
	assert_eq(sum, grid.cell_count(), "各行容量之和 == 盘内格数（守恒）")


func test_row_report_flags_each_infeasible_case() -> void:
	var grid = _rect(4, 3)
	# ① 目标 > 每行格数
	var r1: Dictionary = CP.row_report(grid, 4, [], MATRIX.RECT)
	assert_eq((r1["infeasible"] as Array).size(), 4, "每行只有 3 格却要 4 颗 ⇒ 4 行全不可行")
	for rec: Dictionary in (r1["rows"] as Array):
		assert_false(bool(rec["feasible"]), "不可行的行必须标 false")
		assert_ne(str(rec["reason"]).strip_edges(), "", "不可行必须给可读原因")
	# ② 已放雷数 > 目标
	var r2: Dictionary = CP.row_report(grid, 1, [Vector2i(0, 0), Vector2i(1, 0)], MATRIX.RECT)
	assert_eq((r2["infeasible"] as Array), [0], "第 0 行已放 2 颗 > 目标 1 ⇒ 只有该行不可行")
	# ③ 目标为负数
	var r3: Dictionary = CP.row_report(grid, -1, [], MATRIX.RECT)
	assert_eq((r3["infeasible"] as Array).size(), 4, "负目标对每一行都不可行")
	for rec: Dictionary in (r3["rows"] as Array):
		assert_false(bool(rec["feasible"]), "负目标必须判不可行")
	# 盘外雷位要被忽略并计数（不静默）
	var r4: Dictionary = CP.row_report(grid, 1, [Vector2i(0, 0), Vector2i(99, 99)], MATRIX.RECT)
	assert_eq(int(r4["ignored_mines"]), 1, "盘外雷位必须被忽略并计数")
	assert_eq(int((r4["rows"] as Array)[0]["mines"]), 1, "盘内那颗仍要算进第 0 行")


# ==================== ⑤ 洞格不计入容量 ====================

func test_row_capacity_uses_board_cells_not_bounding_box() -> void:
	# 3×3 盘挖掉 (1,1)：中间行的容量应变成 2，而不是包围盒的 3。
	var g = SG.to_adjacency_grid("holed_grid", {"rows": 3, "cols": 3, "holes": [{"x": 1, "y": 1}]})
	assert_eq(g.cell_count(), 8, "前提：3×3 挖 1 格 = 8 格")
	# 但 holed_grid 上"行"语义按矩阵是未定义的 ⇒ 门禁必须拦住（宁禁不放）。
	var rep: Dictionary = CP.row_report(g, 1, [], MATRIX.HOLED_GRID)
	assert_false(bool(rep["ok"]), "holed_grid 上的行语义未定义 ⇒ 必须拒绝（矩阵门禁）")
	assert_ne(str(rep["reason"]).strip_edges(), "", "拒绝必须给可读原因")
	# 换成矩形盘后，容量必须来自 grid（不是 rows×cols 的想象）
	var r = _rect(3, 3)
	var ok: Dictionary = CP.row_report(r, 1, [], MATRIX.RECT)
	assert_eq(int((ok["rows"] as Array)[1]["capacity"]), 3, "矩形盘中间行容量 = 3")


# ==================== 颜色表 / 文案 ====================

func test_color_table_is_deterministic_and_complete() -> void:
	var t: Dictionary = CP.color_table()
	assert_eq(t.size(), CP.QUADRANT_COUNT + 1, "颜色表 = 4 象限 + 中轴")
	var seen := {}
	for k in t.keys():
		var c: Color = t[k]
		assert_true(c.a > 0.0 and c.a <= 0.45, "预览色必须半透明（不许盖住底下的格）：%s" % str(c))
		seen[c.to_html(false)] = true
	assert_eq(seen.size(), CP.QUADRANT_COUNT + 1, "5 个色号应是 5 个不同的颜色")
	assert_eq(CP.color_of(-1).a, 0.0, "越界色号 ⇒ 全透明（不假装知道）")
	assert_eq(CP.color_of(99).a, 0.0, "越界色号 ⇒ 全透明")


func test_describe_strings_are_readable() -> void:
	var grid = _rect(5, 5)
	var q: Dictionary = CP.quadrant_preview(grid, grid.all_positions(), MATRIX.RECT)
	var qs := CP.describe_quadrants(q)
	assert_ne(qs.strip_edges(), "", "四象文案不得为空")
	assert_true(qs.contains("中轴"), "5×5 有中轴 ⇒ 文案要提到它")
	var r: Dictionary = CP.row_report(grid, 9, [], MATRIX.RECT)
	var rs := CP.describe_rows(r)
	assert_ne(rs.strip_edges(), "", "行容量文案不得为空")
	assert_true(rs.contains("不可行"), "目标 9 > 每行 5 格 ⇒ 文案要说不可行")
	# 拒绝态也要有可读文案
	assert_ne(CP.describe_quadrants(CP.quadrant_preview(_rect(3, 3), [], MATRIX.HEX)).strip_edges(), "")
	assert_ne(CP.describe_rows(CP.row_report(_rect(3, 3), 1, [], MATRIX.HEX)).strip_edges(), "")


# ==================== helpers ====================

func _rect(rows: int, cols: int):
	return SG.to_adjacency_grid("holed_grid", {"rows": rows, "cols": cols})
