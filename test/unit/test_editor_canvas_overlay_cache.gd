# test_editor_canvas_overlay_cache.gd —— 画布「正式叠加 API + 静态层缓存」回归闸门（2026-10-03）。
#
# 对应文档「十.4」（5000 格静态层必须缓存，不能逐帧重绘）与"把运行期挂子 Control 的 HotOverlay
# 收编成正式接口"这笔技术债，逐条钉住：
#   ① 叠加 API：设置 / 覆盖 / 单层清除 / 整体清除 / 多层共存 / 非法数据不崩
#   ② 叠加颜色随主题：红=必猜、蓝=深度；断言取色**等于** ThemeManager 的取色接口（不是硬编码字面量）
#   ③ 静态层缓存失效：invalidate_static_cache() 后可观察地重建（用计数/标志断言，**不做像素比对**）
#   ④ 无头环境下不崩：降级被触发、状态可读、绘制路径仍能走完
#   ⑤ 既有绘制路径回归（几何决策 + 旧接口行为不变，与 test_editor_canvas_tools 同口径）
extends GutTest


func _make_canvas(w: float, h: float) -> EditorCanvas:
	var c := EditorCanvas.new()
	add_child_autofree(c)
	c.size = Vector2(w, h)
	return c


func _doc(rows: int, cols: int) -> EditorDoc:
	return EditorDoc.new(rows, cols)


# ==================== ① 叠加 API ====================

func test_overlay_set_clear_and_multi_layer_coexist() -> void:
	var c := _make_canvas(400, 300)
	c.set_doc(_doc(9, 9))
	assert_false(c.has_overlay("heat"), "新画布不应有任何叠加层")
	assert_eq(c.overlay_names().size(), 0)

	var heat := {Vector2i(1, 1): {"level": 0, "must_guess": false}}
	var focus := {Vector2i(2, 2): {"level": 3, "must_guess": true}}
	c.set_overlay("heat", heat)
	c.set_overlay("focus", focus, {"z": 5})

	assert_true(c.has_overlay("heat"))
	assert_true(c.has_overlay("focus"))
	assert_eq(c.overlay_names(), ["focus", "heat"], "层名应可枚举（升序）")
	assert_eq((c.get_overlay("heat")["cells"] as Dictionary).size(), 1, "heat 层应有 1 格")
	assert_eq(int((c.get_overlay("focus")["opts"] as Dictionary).get("z", 0)), 5, "opts 应原样保留")

	# 同名 = 覆盖（不是叠加）：层数不变
	c.set_overlay("heat", {Vector2i(5, 5): {"level": 1, "must_guess": false}})
	assert_eq(c.overlay_names().size(), 2, "同名设置应覆盖而非新增一层")
	assert_eq((c.get_overlay("heat")["cells"] as Dictionary).size(), 1)
	assert_true((c.get_overlay("heat")["cells"] as Dictionary).has(Vector2i(5, 5)),
		"覆盖后应只剩新数据")

	# 单层清除：只掉那一层
	c.clear_overlay("focus")
	assert_false(c.has_overlay("focus"), "clear_overlay 应删掉指定层")
	assert_true(c.has_overlay("heat"), "clear_overlay 不得误删其它层")

	# 整体清除
	c.set_overlay("third", focus)
	assert_eq(c.overlay_names().size(), 2)
	c.clear_overlays()
	assert_eq(c.overlay_names().size(), 0, "clear_overlays 应清空所有层")

	# 显隐是"关掉但不丢数据"（编辑器热力图开关的接线点）
	c.set_overlay("heat", heat)
	c.set_overlay_visible("heat", false)
	assert_false(bool((c.get_overlay("heat")["opts"] as Dictionary).get("visible", true)),
		"set_overlay_visible(false) 应写入该层 opts.visible")
	assert_eq((c.get_overlay("heat")["cells"] as Dictionary).size(), 1, "显隐不得丢数据")
	c.set_overlay_visible("heat", true)
	assert_true(bool((c.get_overlay("heat")["opts"] as Dictionary).get("visible", true)))
	c.set_overlay_visible("nope", false)
	assert_false(c.has_overlay("nope"), "对不存在的层设显隐应无操作")
	c.clear_overlay("heat")

	# 清除不存在的层 / 空名 / 非法数据都必须无害（不崩）
	c.clear_overlay("nope")
	c.set_overlay("", heat)
	assert_eq(c.overlay_names().size(), 0, "空名不得建层")
	c.set_overlay("bad", {Vector2i(0, 0): 123, "not_a_pos": {"level": 1, "must_guess": true}})
	assert_true(c.has_overlay("bad"), "非法内容层可以存在")
	c.queue_redraw()
	await wait_process_frames(2)
	assert_eq(c.overlay_names(), ["bad"], "非法内容在绘制时被跳过，不得崩也不得被静默删掉")


# ==================== ② 颜色纪律：取色只能来自 ThemeManager ====================

func test_overlay_colors_come_from_theme_manager() -> void:
	var c := _make_canvas(300, 300)
	var danger := ThemeManager.danger()
	var accent := ThemeManager.accent()

	# 必猜格 = 红，rgb 必须与 ThemeManager.danger() **逐通道一致**（说明不是硬编码）
	var guess := c.overlay_cell_color(true, -1, 10)
	assert_almost_eq(guess.r, danger.r, 0.001, "必猜格的 r 必须取自 ThemeManager.danger()")
	assert_almost_eq(guess.g, danger.g, 0.001, "必猜格的 g 必须取自 ThemeManager.danger()")
	assert_almost_eq(guess.b, danger.b, 0.001, "必猜格的 b 必须取自 ThemeManager.danger()")
	assert_almost_eq(guess.a, EditorCanvas.OVERLAY_MUST_GUESS_ALPHA, 0.001)
	assert_false(guess.is_equal_approx(Color(1.0, 0.16, 0.16, 0.55)),
		"不得沿用旧 HotOverlay 里硬编码的那个红")

	# 深度色：基色必须 = accent()，只有透明度随深度变化
	var early := c.overlay_cell_color(false, 0, 10)
	var mid := c.overlay_cell_color(false, 5, 10)
	var late := c.overlay_cell_color(false, 10, 10)
	for col: Color in [early, mid, late]:
		assert_almost_eq(col.r, accent.r, 0.001, "深度色基色必须取自 ThemeManager.accent()")
		assert_almost_eq(col.g, accent.g, 0.001, "深度色基色必须取自 ThemeManager.accent()")
		assert_almost_eq(col.b, accent.b, 0.001, "深度色基色必须取自 ThemeManager.accent()")
	assert_almost_eq(early.a, EditorCanvas.OVERLAY_DEPTH_ALPHA_MIN, 0.001, "深度最浅 = alpha 下限")
	assert_almost_eq(late.a, EditorCanvas.OVERLAY_DEPTH_ALPHA_MAX, 0.001, "深度最深 = alpha 上限")
	assert_true(mid.a > early.a and late.a > mid.a, "深度越深越不透明（单调递增）")

	# 推导不出的格（level<0 且非必猜）不涂：留白 = 未知，绝不假装知道
	assert_eq(c.overlay_cell_color(false, -1, 10).a, 0.0, "level<0 且非必猜不得涂色")

	# opts 能覆盖归一化上限与透明度，但**不能**改基色（仍须来自主题）
	var deep := c.overlay_cell_color(false, 3, 100, {"max_level": 3, "alpha_max": 0.9})
	assert_almost_eq(deep.a, 0.9, 0.001, "opts.alpha_max 应生效")
	assert_almost_eq(deep.r, accent.r, 0.001, "opts 不得改变基色来源")


# ==================== ③ 静态层缓存：可观察的失效 / 重建 ====================

func test_static_cache_invalidation_rebuilds_observably() -> void:
	var c := _make_canvas(400, 300)
	c.set_doc(_doc(9, 9))
	c.ensure_static_cache()
	# 状态机必须二选一：要么纹理就绪，要么明确降级（两者都否 = 有分支漏了）
	assert_true(c.static_cache_ready() or c.static_cache_degraded(),
		"缓存状态必须二选一：ready 或 degraded")

	var b0 := c.static_cache_builds()
	c.ensure_static_cache()
	assert_eq(c.static_cache_builds(), b0, "内容未变时不得重建（否则就退化成每帧重绘）")

	var i0 := c.static_cache_invalidations()
	c.invalidate_static_cache("单测失效")
	assert_eq(c.static_cache_invalidations(), i0 + 1, "失效次数应可观察")
	c.ensure_static_cache()
	assert_eq(c.static_cache_builds(), b0 + 1, "显式失效后必须重建一次")

	# 改盘面（走画布写入口 = 所有工具的收口）⇒ 自动重建，不依赖显式失效
	var b1 := c.static_cache_builds()
	c.apply_kind(Vector2i(0, 0), EditorCanvas.KIND_MINE)
	c.ensure_static_cache()
	assert_eq(c.static_cache_builds(), b1 + 1, "格子集变化后必须重建缓存")

	# 直接改文档（编辑器里确有这种绕过画布写入口的路径）⇒ 内容指纹兜底重建
	var b2 := c.static_cache_builds()
	c.doc.mines.append(Vector2i(3, 3))
	c.ensure_static_cache()
	assert_eq(c.static_cache_builds(), b2 + 1, "文档内容变化后必须重建缓存（指纹兜底）")

	# 显示开关
	var b3 := c.static_cache_builds()
	c.set_show_grid(false)
	c.ensure_static_cache()
	assert_eq(c.static_cache_builds(), b3 + 1, "网格线开关变化后必须重建缓存")

	# 换文档（棋盘尺寸/格子集全换）
	var b4 := c.static_cache_builds()
	c.set_doc(_doc(16, 16))
	c.ensure_static_cache()
	assert_eq(c.static_cache_builds(), b4 + 1, "换文档后必须重建缓存")

	# 缩放（格宽变了 ⇒ 纹理尺寸变）必须重建；纯平移**不得**重建（缓存是"盘局部"的）
	var b5 := c.static_cache_builds()
	c.zoom = 2.0
	c.ensure_static_cache()
	assert_eq(c.static_cache_builds(), b5 + 1, "缩放（格宽变）后必须重建缓存")
	var b6 := c.static_cache_builds()
	c.pan += Vector2(37.0, -21.0)
	c.ensure_static_cache()
	assert_eq(c.static_cache_builds(), b6, "纯平移不得重建缓存（否则一拖视口就重画整盘）")


# ==================== ③b 静态层图像本身（`Image` API 无头下也能跑 ⇒ 覆盖"真缓存"栅格化） ====================

func test_static_image_paints_theme_colors_and_grid() -> void:
	var c := _make_canvas(400, 300)
	var d := _doc(9, 9)
	d.mines.append(Vector2i(2, 2))
	d.revealed[Vector2i(3, 3)] = null
	c.set_doc(d)
	var cp := c.cell_px()
	var img: Image = c._build_static_image()
	assert_not_null(img, "静态层图像必须能构建（Image API 无头也可用）")
	assert_eq(img.get_width(), int(ceil(9.0 * cp)), "图像宽度应 = 整盘像素宽")
	assert_eq(img.get_height(), int(ceil(9.0 * cp)), "图像高度应 = 整盘像素高")

	# 三种格底色都必须与 ThemeManager 的取色一致（容差覆盖 8bit 量化）
	var hidden := ThemeManager.cell_hidden()
	var px_hidden := img.get_pixel(5, 5)
	assert_almost_eq(px_hidden.r, hidden.r, 0.01, "隐藏格底色必须来自 ThemeManager.cell_hidden()")
	assert_almost_eq(px_hidden.g, hidden.g, 0.01)
	assert_almost_eq(px_hidden.b, hidden.b, 0.01)

	var revealed := ThemeManager.cell_revealed()
	var px_rev := img.get_pixel(int(round(3.0 * cp)) + 3, int(round(3.0 * cp)) + 3)
	assert_almost_eq(px_rev.r, revealed.r, 0.01, "翻开格底色必须来自 ThemeManager.cell_revealed()")
	assert_almost_eq(px_rev.b, revealed.b, 0.01)

	var mine_col := ThemeManager.cell_hidden().darkened(0.25)
	var px_mine := img.get_pixel(int(round(2.0 * cp)) + 3, int(round(2.0 * cp)) + 3)
	assert_almost_eq(px_mine.r, mine_col.r, 0.02, "雷格底色必须由主题色加深得出（不得硬编码）")
	assert_almost_eq(px_mine.b, mine_col.b, 0.02)

	# 网格线：格边界的像素不得等于格底色（说明线真的画进了缓存，且走的是主题线色）
	assert_false(img.get_pixel(0, 5).is_equal_approx(px_hidden), "格边界应画上网格线")


# ==================== ④ 无头环境：降级但不崩 ====================

func test_headless_degrades_without_crashing() -> void:
	var c := _make_canvas(400, 300)
	c.set_doc(_doc(20, 20))
	var ok := c.ensure_static_cache()
	var headless := DisplayServer.get_name() == "headless"
	if headless:
		assert_false(ok, "无头环境必须走降级（不分配纹理）")
		assert_true(c.static_cache_degraded(), "无头环境应标记为降级态")
		assert_false(c.static_cache_ready(), "降级态不得报告纹理就绪")
		assert_true(c.static_cache_reason().find("无头") != -1,
			"降级原因必须可读：%s" % c.static_cache_reason())
	else:
		assert_true(ok and c.static_cache_ready(), "有渲染环境时应真的建出缓存纹理")
		assert_false(c.static_cache_degraded(), "有渲染环境不应降级")

	# 无论降级与否，绘制路径都要能走完（真跑两帧）
	c.set_highlight([Vector2i(1, 1)])
	c.set_overlay("heat", {Vector2i(2, 2): {"level": 1, "must_guess": true}})
	c.queue_redraw()
	await wait_process_frames(2)
	assert_eq(c.static_cache_ready(), ok, "重绘不得把缓存状态改坏")

	if headless:
		assert_gt(c.static_cache_direct_draws(), 0,
			"降级必须真的被执行（否则'降级'只是标志位）：_draw 应走直绘路径")


# ==================== ⑤ 既有绘制路径回归 ====================

func test_existing_draw_path_still_works() -> void:
	var c := _make_canvas(600, 600)
	c.set_doc(_doc(9, 9))
	# 几何决策与既有实现完全一致（cache 不得改变 cell_rect / 网格步长）
	assert_eq(c.grid_line_step(), 1, "9x9@600px 应逐格画细线")
	assert_eq(c.cell_rect(Vector2i(0, 0)).size, Vector2(c.cell_px(), c.cell_px()))
	assert_eq(c.pos_at(c.cell_rect(Vector2i(4, 4)).get_center()), Vector2i(4, 4),
		"cell_rect 与 pos_at 必须仍然互逆")

	# 大棋盘：粗网格策略不变
	var big := _make_canvas(200, 200)
	big.set_doc(_doc(40, 40))
	assert_true(big.grid_line_step() > 1, "格宽过小时必须退化粗网格（与旧行为一致）")

	# 旧接口全部照旧：预览值 / 高亮 / 选区 / 显雷 / 网格开关
	var sel := Rect2i(1, 1, 2, 2)
	c.set_values({Vector2i(1, 1): 3})
	c.set_highlight([Vector2i(1, 1)])
	c.set_selection(sel)
	assert_eq(c.selection, sel, "set_selection 行为不得变")
	c.set_show_mines(false)
	assert_false(c.show_mines)
	c.set_show_grid(false)
	assert_eq(c.grid_line_step(), 0, "关掉网格线后不得画网格（与旧行为一致）")
	c.set_show_grid(true)
	assert_eq(c.grid_line_step(), 1, "开回来应恢复细网格（与旧行为一致）")
	c.queue_redraw()
	await wait_process_frames(2)
	assert_eq(c.grid_line_step(), 1, "反复重绘后网格决策不得漂移")
	assert_eq(c.selection, sel, "重绘不得改选区")
