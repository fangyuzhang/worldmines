# test_editor_canvas_tools.gd —— 画布侧新增工具 / 显示项的回归闸门（2026-10-03）。
#
# 对应文档「一、基础操作」「四、绘制工具」的缺口，逐条钉住：
#   ① 直线命中格集合（Bresenham 纯函数 + 真实输入路径落笔）
#   ② 油漆桶只染"连通的同型区"（两块不连通区域，只染一块）
#   ③ 洪泛超上限会停止，且结果可读（含上限数字）
#   ④ show_grid 开关生效（绘制决策 + 红绘不崩）
#   ⑤ 小地图矩形纯函数边界（棋盘小于视口 ⇒ 不画；大于视口 ⇒ 边界正确）
#   ⑥ 空格平移态（左键拖动只平移、不改盘面）
extends GutTest


func _make_canvas(w: float, h: float) -> EditorCanvas:
	var c := EditorCanvas.new()
	add_child_autofree(c)
	c.size = Vector2(w, h)
	return c


func _cells_text(arr: Array) -> String:
	var parts: Array[String] = []
	for p in arr:
		parts.append(str(p))
	return "[" + ", ".join(parts) + "]"


# ==================== ① 直线 ====================

func test_line_cells_horizontal_diagonal_and_symmetry() -> void:
	var h := EditorCanvas.line_cells(Vector2i(0, 0), Vector2i(4, 0))
	assert_eq(h.size(), 5, "水平直线应命中 5 格：%s" % _cells_text(h))
	assert_eq(h[0], Vector2i(0, 0))
	assert_eq(h[4], Vector2i(4, 0))

	var d := EditorCanvas.line_cells(Vector2i(0, 0), Vector2i(3, 3))
	assert_eq(d.size(), 4, "45° 直线应逐格对角：%s" % _cells_text(d))
	for i in 4:
		assert_eq(d[i], Vector2i(i, i), "对角线第 %d 格应是 (%d,%d)" % [i, i, i])

	# 陡峭斜线：格数 = max(dx,dy)+1，且相邻格必须 8 邻接（Bresenham 不得跳格）
	var s := EditorCanvas.line_cells(Vector2i(0, 0), Vector2i(2, 5))
	assert_eq(s.size(), 6, "陡峭斜线格数 = max(dx,dy)+1：%s" % _cells_text(s))
	assert_eq(s[0], Vector2i(0, 0))
	assert_eq(s[s.size() - 1], Vector2i(2, 5))
	for i in range(1, s.size()):
		var step: Vector2i = (s[i] - s[i - 1]).abs()
		assert_true(step.x <= 1 and step.y <= 1 and step != Vector2i.ZERO,
			"相邻命中格必须 8 邻接（不得跳格）：%s → %s" % [str(s[i - 1]), str(s[i])])

	# 端点互换 ⇒ 同一集合（对称性；否则"从左往右拖"与"从右往左拖"会画出两条线）
	var s_set := {}
	for p in s:
		s_set[p] = true
	var r := EditorCanvas.line_cells(Vector2i(2, 5), Vector2i(0, 0))
	assert_eq(r.size(), s.size(), "反向走线格数应一致")
	for p in r:
		assert_true(s_set.has(p), "反向走线不得偏离正向集合：%s" % str(p))


func test_line_tool_paints_along_the_drag() -> void:
	# 走真实输入路径：按下 → 拖动 → 抬起，验证"抬起才落笔 + 复用当前 paint_kind"。
	var c := _make_canvas(600, 600)
	var d := EditorDoc.new(9, 9)
	c.set_doc(d)
	c.tool = EditorCanvas.Tool.LINE
	c.paint_kind = EditorCanvas.KIND_OBSTACLE

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = c.cell_rect(Vector2i(0, 4)).get_center()
	c._gui_input(down)
	assert_eq(d.obstacles.size(), 0, "直线在抬起前不得落笔（否则拖动中会一条条乱画）")

	var mv := InputEventMouseMotion.new()
	mv.position = c.cell_rect(Vector2i(8, 4)).get_center()
	mv.button_mask = MOUSE_BUTTON_MASK_LEFT
	c._gui_input(mv)

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = c.cell_rect(Vector2i(8, 4)).get_center()
	c._gui_input(up)

	assert_eq(d.obstacles.size(), 9, "直线工具应沿拖动落满一条横线：%s" % str(d.obstacles))
	for x in 9:
		assert_true(d.obstacles.has(Vector2i(x, 4)), "缺格 (%d,4)" % x)


# ==================== ② 油漆桶：只染连通的同型区 ====================

func test_bucket_only_fills_connected_same_kind_region() -> void:
	# 左块 x=0..3 全雷；右块 x=5..8 全雷；中间 x=4 是"空"。
	# 8 邻接也跨不过去（x=3 与 x=5 间隔 2）⇒ 两块互不连通。
	var d := EditorDoc.new(9, 9)
	for y in 9:
		for x in range(0, 4):
			d.mines.append(Vector2i(x, y))
		for x in range(5, 9):
			d.mines.append(Vector2i(x, y))
	var c := _make_canvas(400, 300)
	c.set_doc(d)

	var res: Dictionary = c.bucket_cells(Vector2i(0, 0))
	assert_eq(int(res["filled"]), 36, "应只覆盖左块（4 列 × 9 行）：%d" % int(res["filled"]))
	assert_false(bool(res["truncated"]), "小区域不得触顶")

	# 真落笔：把左块染成「障碍」，右块必须原样（这是本条用例的核心断言）
	c.tool = EditorCanvas.Tool.BUCKET
	c.paint_kind = EditorCanvas.KIND_OBSTACLE
	c._apply_bucket(Vector2i(0, 0))
	assert_eq(d.obstacles.size(), 36, "左块应整块变成障碍：%d" % d.obstacles.size())
	assert_eq(d.mines.size(), 36, "右块雷位不得被动（只剩右块 36 颗）：%d" % d.mines.size())
	assert_true(d.obstacles.has(Vector2i(0, 0)), "种子格应变成障碍")
	assert_true(d.mines.has(Vector2i(5, 0)), "右块 (5,0) 必须仍是一颗雷")
	assert_false(d.obstacles.has(Vector2i(5, 0)), "右块不得被染成障碍")


# ==================== ③ 洪泛超上限 ====================

func test_bucket_flood_stops_at_visit_limit_with_readable_result() -> void:
	# 默认上限必须与文档预算的硬阻上限同值（写死两处迟早漂移，"卡死防护"就落空）。
	assert_eq(EditorCanvas.BUCKET_VISIT_LIMIT, EditorDoc.MAX_CELL_BUDGET,
		"洪泛上限应与 EditorDoc.MAX_CELL_BUDGET 一致")

	var d := EditorDoc.new(12, 12)      # 144 格全"空" ⇒ 一整块连通同型区
	var c := _make_canvas(400, 300)
	c.set_doc(d)
	# 注入小上限来验截断（否则要造 >5000 格的非法大盘，反而会撞加载器的 4096 上限）
	var res: Dictionary = c.bucket_cells(Vector2i(0, 0), 10)
	assert_true(bool(res["truncated"]), "区域大于上限时必须触顶停止（否则点一下会同步卡死）")
	assert_eq(int(res["filled"]), 10, "触顶时应恰好停在给定上限")
	var reason := str(res["reason"])
	assert_true(reason.find("10") != -1, "结果里要有可读原因（含上限数字）：%s" % reason)

	# 反向守卫：没超上限时结果应完整、且不得谎报截断
	var whole: Dictionary = c.bucket_cells(Vector2i(0, 0), 1000)
	assert_false(bool(whole["truncated"]), "144 格区域在 1000 上限下不得报截断")
	assert_eq(int(whole["filled"]), 144, "未触顶时应填满整块：%d" % int(whole["filled"]))


# ==================== ④ 网格线开关 ====================

func test_show_grid_switch_and_coarse_strategy() -> void:
	var c := _make_canvas(200, 200)
	var d := EditorDoc.new(40, 40)      # 格宽被算到 < 6px ⇒ 应退化为粗网格
	c.set_doc(d)
	assert_true(c.show_grid, "默认应显示网格线")
	assert_true(c.grid_line_step() > 1,
		"格宽 < %.0fpx 时应改画粗网格（步长 > 1），否则就是逐格画到卡死那条路" % EditorCanvas.GRID_THIN_MIN_PX)
	c.show_grid = false
	assert_eq(c.grid_line_step(), 0, "关掉 show_grid 后必须不画网格线")
	c.show_grid = true
	assert_true(c.grid_line_step() > 1)

	# 正常格宽应回到逐格细线（步长 1）
	var c2 := _make_canvas(600, 600)
	c2.set_doc(EditorDoc.new(9, 9))
	assert_eq(c2.grid_line_step(), 1, "格宽足够大时应逐格画细线")


func test_toggling_grid_does_not_crash_the_draw_path() -> void:
	var c := _make_canvas(240, 200)
	c.set_doc(EditorDoc.new(9, 9))
	var before := c.grid_line_step()
	c.show_grid = false
	c.queue_redraw()
	c.show_grid = true
	c.queue_redraw()
	await wait_process_frames(2)
	assert_eq(c.grid_line_step(), before, "开关来回不应改变细网格步长决策")
	assert_true(c.grid_line_step() >= 1)


# ==================== ⑤ 小地图纯函数 ====================

func test_minimap_rect_empty_when_board_fits_view() -> void:
	var c := _make_canvas(400, 300)
	c.set_doc(EditorDoc.new(5, 5))
	assert_eq(c.minimap_rect().size, Vector2.ZERO, "棋盘没超出可视区域时不应画小地图")
	assert_false(c.board_overflows_view())
	# 无文档也更不能崩
	var empty := _make_canvas(400, 300)
	assert_eq(empty.minimap_rect().size, Vector2.ZERO, "无文档时小地图应为空")


func test_minimap_rect_when_board_overflows_view() -> void:
	var c := _make_canvas(200, 200)
	c.set_doc(EditorDoc.new(40, 40))
	c.zoom = 4.0                        # 放大到棋盘（≈752px）远超视口（200px）
	assert_true(c.board_overflows_view(), "放大后棋盘应超出视口")
	var mr := c.minimap_rect()
	assert_true(mr.size.x > 0.0 and mr.size.y > 0.0, "棋盘超出视口时应给出小地图矩形")
	assert_true(mr.position.x >= 0.0 and mr.position.y >= 0.0, "小地图应落在画布内：%s" % str(mr))
	assert_true(mr.end.x <= c.size.x + 0.01 and mr.end.y <= c.size.y + 0.01, "小地图不得越出画布：%s" % str(mr))
	assert_true(is_equal_approx(mr.end.x, c.size.x - EditorCanvas.MINIMAP_MARGIN),
		"右边距应固定为 MINIMAP_MARGIN：%.2f" % mr.end.x)
	assert_almost_eq(mr.size.y, mr.size.x * 40.0 / 40.0, 0.5, "方形盘的小地图也应是方形")
	# 点击小地图中心 ⇒ 视口中心落到盘中心附近
	assert_eq(c.minimap_to_cell(mr.get_center()), Vector2i(20, 20), "小地图中心应映射到棋盘中心格")
	c.center_on_cell(Vector2i(20, 20))
	assert_eq(c.pos_at(c.size * 0.5), Vector2i(20, 20), "center_on_cell 后画布中心应正对该格")


# ==================== ⑥ 空格平移态 ====================

func test_space_pan_mode_pans_without_painting() -> void:
	var c := _make_canvas(400, 300)
	var d := EditorDoc.new(9, 9)
	c.set_doc(d)
	c.tool = EditorCanvas.Tool.PAINT
	c.set_pan_mode(true)

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = c.cell_rect(Vector2i(4, 4)).get_center()
	c._gui_input(down)
	assert_eq(d.mines.size(), 0, "平移态下按下左键不得画格子")

	var mv := InputEventMouseMotion.new()
	mv.position = down.position + Vector2(40, 25)
	mv.button_mask = MOUSE_BUTTON_MASK_LEFT
	c._gui_input(mv)
	assert_eq(c.pan, Vector2(40, 25), "平移态下拖动应改变 pan：%s" % str(c.pan))

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = mv.position
	c._gui_input(up)
	assert_false(c._panning, "抬起后必须结束平移（否则松手后鼠标一动整盘还跟着跑）")
	assert_eq(d.mines.size(), 0, "整个平移手势不得改盘面")
