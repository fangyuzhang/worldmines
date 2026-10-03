# test_shape_reflow.gd —— 缺口 #5「形状参数改变后的重栅格化 + 保留手工格」的钉子（2026-10-04）。
#
# 被测：core/shape_reflow.gd（纯函数）。四个用例逐一钉住行为：
#   ① 未改格：新形状生效（旧有新无、新有旧无）；
#   ② 手工格盘内：保留（即使新形状不含它），kept_hand 与断言一致；
#   ③ 手工格盘外（新形状外）：进 dropped_hand 且结果 cells 里没有它；
#   ④ 判界走网格（不是包围盒）：环形 annulus 的**洞格**在包围盒内，但不在盘上 ⇒
#      洞格上的手工格必须被丢弃并报告（若按 cols/rows 包围盒判界会误留）。
#   ⑤ 手改负载优先：同一格既是 hand_edited 又在新形状里 ⇒ cells 取手改负载，不被新形状默认值覆盖。
extends GutTest

const REFLOW := preload("res://core/shape_reflow.gd")
const GENERATOR := preload("res://core/shape_generator.gd")
const RECT_GRID := preload("res://core/rect_grid.gd")


func _rect_grid(rows: int, cols: int):
	var g = RECT_GRID.new()
	g.setup(rows, cols)
	return g


func _cell_set(positions: Array) -> Dictionary:
	var d := {}
	for p in positions:
		d[p] = true
	return d


# ==================== ① 未改格：新形状生效 ====================

func test_unchanged_cells_follow_the_new_shape() -> void:
	var grid = _rect_grid(6, 6)
	var old_cells := _cell_set([Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 3)])
	var new_cells := _cell_set([Vector2i(0, 0), Vector2i(2, 0), Vector2i(4, 4)])
	var r: Dictionary = REFLOW.reflow(grid, old_cells, new_cells, {})
	var cells: Dictionary = r["cells"]
	assert_true(cells.has(Vector2i(0, 0)), "新旧都有的格保留")
	assert_true(cells.has(Vector2i(2, 0)), "新旧都有的格保留")
	assert_true(cells.has(Vector2i(4, 4)), "新形状新增的格出现")
	assert_false(cells.has(Vector2i(1, 0)), "旧形状独有的格消失")
	assert_false(cells.has(Vector2i(3, 3)), "旧形状独有的格消失")
	assert_eq(cells.size(), 3, "结果格集 = 新形状格集（无手工格时逐格相同）")
	assert_eq((r["kept_hand"] as Array).size(), 0, "无手工格 ⇒ kept_hand 为空")
	assert_eq((r["dropped_hand"] as Array).size(), 0, "无手工格 ⇒ dropped_hand 为空")
	assert_eq(str(r["reason"]), "", "没有丢弃 ⇒ reason 为空串")


# ==================== ② 手工格盘内：保留（即使新形状不含它） ====================
#
# 注：本用例让 grid（判界盘）比 new_cells（新形状栅格）宽。**UI 实际接线不会走这条路径**——
# 真实编辑器 grid = EditorDoc.grid() = 新形状盘 ⇒ in_board 与 new_cells 同源。本条仅作纯函数
# 契约测试：冻结「判界只问 grid、new_cells 只管未改格、手工格负载不被覆盖」，防将来有人把
# 判界改成「只用 new_cells 判」而丢掉手工负载。

func test_hand_edited_cells_inside_board_are_kept_even_outside_new_shape() -> void:
	var grid = _rect_grid(6, 6)
	var new_cells := {}
	for y in range(3):
		for x in range(3):
			new_cells[Vector2i(x, y)] = "new"
	var outside_shape := Vector2i(5, 5)   # 盘内，但不在 3x3 新形状里
	var inside_shape := Vector2i(1, 1)    # 盘内且在新形状里
	var hand := {outside_shape: true, inside_shape: true}
	var old_cells := {outside_shape: "mine", inside_shape: "mine"}
	var r: Dictionary = REFLOW.reflow(grid, old_cells, new_cells, hand)
	var cells: Dictionary = r["cells"]
	assert_true(grid.in_board(outside_shape), "前提：该格在盘内")
	assert_false(new_cells.has(outside_shape), "前提：该格不在新形状里")
	assert_true(cells.has(outside_shape), "盘内手工格必须保留（即使新形状不含它）")
	assert_true(cells.has(inside_shape), "盘内且在形状内的手工格当然保留")
	assert_eq(r["kept_hand"], [inside_shape, outside_shape], "kept_hand 与断言一致（按 (y,x) 排序）")
	assert_eq((r["dropped_hand"] as Array).size(), 0, "无盘外手工格 ⇒ 不丢弃")
	assert_eq(cells[outside_shape], "mine", "保留的手工格沿用旧负载")
	assert_eq(cells[inside_shape], "mine",
		"在新形状里的手工格：手改负载优先，不许被新形状默认值（\"new\"）覆盖")


# ==================== ③ 手工格盘外（新形状外）：丢弃并报告 ====================

func test_hand_edited_cells_outside_the_new_shape_are_dropped_and_reported() -> void:
	var circle = GENERATOR.to_adjacency_grid("circle", {"radius": 3, "precision": 24})
	assert_not_null(circle, "前提：能建出圆形盘")
	var new_cells: Dictionary = {}
	for p in circle.all_positions():
		new_cells[p] = "new"
	var outside := Vector2i(30, 30)   # 圆以 (3,3) 为心、半径 3 ⇒ 远在新盘之外
	assert_false(circle.in_board(outside), "前提：该格确实不在新盘上")
	var hand := {outside: true}
	var old_cells := {outside: "mine"}
	var r: Dictionary = REFLOW.reflow(circle, old_cells, new_cells, hand)
	assert_eq(r["dropped_hand"], [outside], "盘外手工格进 dropped_hand（必须报告）")
	assert_false((r["cells"] as Dictionary).has(outside), "cells 里不许有被丢弃的手工格")
	assert_ne(str(r["reason"]), "", "丢弃必须给可读 reason（不许静默丢）")
	assert_eq((r["kept_hand"] as Array).size(), 0, "该手工格盘外 ⇒ 未保留")


# ==================== ④ 判界走网格：环形洞格的手工格必须被丢弃 ====================

func test_annulus_hole_hand_cell_is_dropped_by_grid_boundary_not_bbox() -> void:
	var ann = GENERATOR.to_adjacency_grid("annulus",
		{"outer_radius": 6, "inner_radius": 3, "precision": 24})
	assert_not_null(ann, "前提：能建出环形（annulus）盘")
	assert_gt(ann.all_positions().size(), 0, "前提：环盘非空")

	var new_cells: Dictionary = {}
	var min_x := 1 << 30
	var max_x := -(1 << 30)
	var min_y := 1 << 30
	var max_y := -(1 << 30)
	for p in ann.all_positions():
		new_cells[p] = "new"
		min_x = mini(min_x, p.x)
		max_x = maxi(max_x, p.x)
		min_y = mini(min_y, p.y)
		max_y = maxi(max_y, p.y)

	# 洞格 = 环中心（内圆挖空处）。它落在包围盒内 ⇒ 按 cols/rows 包围盒判界会误判为「盘内」。
	var hole := Vector2i((min_x + max_x) / 2, (min_y + max_y) / 2)
	assert_false(ann.in_board(hole), "前提：环中心的洞格不在盘上（in_board = false）")
	assert_true(hole.x >= min_x and hole.x <= max_x and hole.y >= min_y and hole.y <= max_y,
		"前提：洞格在包围盒内 ⇒ 说明「按包围盒判界」一定会误留它")

	var hand := {hole: true}
	var old_cells := {hole: "mine"}
	var r: Dictionary = REFLOW.reflow(ann, old_cells, new_cells, hand)
	assert_eq(r["dropped_hand"], [hole], "洞格上的手工格必须被丢弃并报告")
	assert_false((r["cells"] as Dictionary).has(hole), "cells 里不许含洞格")
	assert_ne(str(r["reason"]), "", "洞格被丢弃必须给可读 reason")
	# 对照：环上（盘内）的格若手工改过必须保留，证明丢弃是「判界」而非「一刀切清空」。
	var on_ring := ann.all_positions()[0]
	var r2: Dictionary = REFLOW.reflow(ann, {on_ring: "mine"}, new_cells, {on_ring: true})
	assert_eq(r2["kept_hand"], [on_ring], "环上（盘内）手工格必须保留")
	assert_eq((r2["dropped_hand"] as Array).size(), 0, "环上手工格不该被丢弃")


# ==================== ⑤ 手改负载优先：新形状默认值不得覆盖手工修改 ====================

func test_hand_edited_payload_wins_over_new_shape_payload() -> void:
	var grid = _rect_grid(4, 4)
	# 同一个格：既被手改过、又出现在新形状里，且新形状默认值与它的旧（手改后）值不同。
	var p := Vector2i(2, 2)
	var old_cells := {p: "hand"}          # 旧状态 = 用户手工改后的值
	var new_cells := {p: "shape_def"}     # 新形状默认值（与旧值不同）
	var hand := {p: true}                 # 该格确实被手工改过
	var r: Dictionary = REFLOW.reflow(grid, old_cells, new_cells, hand)
	assert_eq(r["cells"][p], "hand", "手改负载优先：新形状默认值不得覆盖手工修改")
	assert_eq(r["kept_hand"], [p], "该格被保留并报告在 kept_hand")
	assert_ne(r["cells"][p], "shape_def", "结果绝不是新形状默认值")

	# 兜底：old_cells 没有该格时，手改负载退用 hand_edited 的值（仍优先于新形状默认值）。
	var q := Vector2i(0, 0)
	var r2: Dictionary = REFLOW.reflow(grid, {}, {q: "shape_def"}, {q: "hand_q"})
	assert_eq(r2["cells"][q], "hand_q", "old_cells 缺该格时，手改负载退用 hand_edited 值")


# ==================== describe_reflow：UI 一行文案 ====================

func test_describe_reflow_reports_kept_and_dropped_counts() -> void:
	var grid = _rect_grid(5, 5)
	var r: Dictionary = REFLOW.reflow(grid, {}, {}, {Vector2i(0, 0): true, Vector2i(9, 9): true})
	var text := REFLOW.describe_reflow(r)
	assert_true(text.contains("保留"), "文案要说明保留了什么：%s" % text)
	assert_true(text.contains("丢弃"), "文案要说明丢弃了什么：%s" % text)
	assert_true(text.contains("保留了 1 格"), "文案要带上真实数字（保留 1）：%s" % text)
	assert_true(text.contains("丢弃了 1 格"), "文案要带上真实数字（丢弃 1）：%s" % text)

	var empty_text := REFLOW.describe_reflow(REFLOW.reflow(grid, {}, {}, {}))
	assert_ne(empty_text, "", "无手工格时也给一句可读文案（不许空串）")
