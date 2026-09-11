# test_drawing_layer.gd —— 绘画覆盖层
# 验证：模式切换/事件拦截、绘制、撤销重做、清空可撤销、擦除、序列化往返。
extends GutTest

var _layer: DrawingLayer


func before_each() -> void:
	_layer = load("res://ui/drawing_layer.tscn").instantiate()
	add_child_autofree(_layer)


# D1：初始状态（非绘画模式，不拦截）
func test_d1_builds() -> void:
	assert_not_null(_layer, "绘画层应能实例化")
	assert_false(_layer.paint_mode, "初始非绘画模式")
	assert_eq(_layer.mouse_filter, Control.MOUSE_FILTER_IGNORE, "非绘画模式不拦截")


# D2：进入绘画模式 → 拦截鼠标；退出 → 恢复
func test_d2_paint_mode_toggles_mouse_filter() -> void:
	_layer.set_paint_mode(true)
	assert_true(_layer.paint_mode)
	assert_eq(_layer.mouse_filter, Control.MOUSE_FILTER_STOP, "绘画模式拦截鼠标")
	_layer.set_paint_mode(false)
	assert_eq(_layer.mouse_filter, Control.MOUSE_FILTER_IGNORE)


# D3：绘制一笔 → 产生一个含多点笔画
func test_d3_draw_adds_stroke() -> void:
	_layer._start_draw(Vector2(10, 10))
	_layer._active_stroke["points"].append(Vector2(20, 20))
	_layer._active_stroke["points"].append(Vector2(30, 30))
	_layer._finish_draw()
	assert_eq(_layer.strokes.size(), 1, "应有一笔")
	assert_eq(_layer.strokes[0]["points"].size(), 3, "笔画应有 3 个点")


# D4：撤销 / 重做
func test_d4_undo_redo() -> void:
	_layer._start_draw(Vector2(0, 0))
	_layer._finish_draw()
	assert_eq(_layer.strokes.size(), 1)
	_layer.undo()
	assert_eq(_layer.strokes.size(), 0, "撤销后清空")
	_layer.redo()
	assert_eq(_layer.strokes.size(), 1, "重做后恢复")


# D5：清空可撤销（清空压入撤销栈）
func test_d5_clear_all_undoable() -> void:
	for i in 3:
		_layer._start_draw(Vector2(i * 10.0, 0))
		_layer._finish_draw()
	assert_eq(_layer.strokes.size(), 3)
	_layer.clear_all()
	assert_eq(_layer.strokes.size(), 0, "清空后无笔画")
	_layer.undo()
	assert_eq(_layer.strokes.size(), 3, "撤销清空应恢复全部")


# D6：擦除整笔 + 可撤销
func test_d6_erase_removes_stroke() -> void:
	_layer._start_draw(Vector2(0, 0))
	_layer._active_stroke["points"].append(Vector2(10, 0))
	_layer._finish_draw()
	assert_eq(_layer.strokes.size(), 1)
	_layer._start_erase()
	_layer._erase_at(Vector2(5, 0))
	_layer._finish_erase()
	assert_eq(_layer.strokes.size(), 0, "擦除后清空")
	_layer.undo()
	assert_eq(_layer.strokes.size(), 1, "撤销擦除应恢复")


# D7：序列化往返（含颜色/粗细/坐标）
func test_d7_serialization_roundtrip() -> void:
	_layer.set_color(2)
	_layer.set_brush_size(2)
	_layer._start_draw(Vector2(5, 5))
	_layer._active_stroke["points"].append(Vector2(15, 15))
	_layer._finish_draw()
	var data := _layer.get_save_data()
	var layer2: DrawingLayer = load("res://ui/drawing_layer.tscn").instantiate()
	add_child_autofree(layer2)
	layer2.load_save_data(data)
	assert_eq(layer2.strokes.size(), 1, "恢复应有 1 笔")
	assert_eq(layer2.current_color, 2)
	assert_eq(layer2.current_size, 2)
	assert_true(layer2.strokes[0]["color"] is Color, "颜色应为具体色值（主题切换不回变）")


# D8：退出绘画模式后痕迹淡化（草稿态：可见但不干扰读盘）
# 用相对比较而非绝对值，避免依赖本机 settings 里的 drawing_opacity 实际取值
func test_d8_dims_when_not_painting() -> void:
	_layer.set_paint_mode(true)
	var painting_a: float = _layer.modulate.a
	_layer.set_paint_mode(false)
	var idle_a: float = _layer.modulate.a
	assert_true(idle_a < painting_a, "退出绘画模式后绘画痕迹应更淡")
	assert_true(abs(idle_a - painting_a * DrawingLayer.DIM_FACTOR) < 0.001,
			"淡化后不透明度应为绘画时的 DIM_FACTOR 倍")


# D9：刚实例化、从未进入绘画模式时即为草稿淡化态
func test_d9_starts_dimmed() -> void:
	var initial_a: float = _layer.modulate.a
	assert_false(_layer.paint_mode, "初始非绘画模式")
	_layer.set_paint_mode(true)
	assert_true(initial_a < _layer.modulate.a, "初始浓度应低于绘画模式（草稿态）")


## 画一条 5 点横线（x = 0/10/20/30/40，y = 0）。默认粗细 SIZES[1]=4 → 擦除半径 8
func _draw_five_point_line() -> void:
	_layer._start_draw(Vector2(0, 0))
	for x in [10, 20, 30, 40]:
		_layer._active_stroke["points"].append(Vector2(x, 0))
	_layer._finish_draw()


# D10：局部擦除 —— 只擦覆盖到的片段，两端残余留成独立笔画，且可撤销还原
func test_d10_partial_erase_splits_stroke() -> void:
	_layer.erase_mode = DrawingLayer.EraseMode.PARTIAL
	_draw_five_point_line()
	assert_eq(_layer.strokes.size(), 1)

	# 擦中间点 (20,0)：半径 8，仅该点落入范围 → 切成 [0,10] 与 [30,40] 两段
	_layer._start_erase()
	_layer._erase_at(Vector2(20, 0))
	_layer._finish_erase()

	assert_eq(_layer.strokes.size(), 2, "局部擦除应把一笔切成两段")
	assert_eq(_layer.strokes[0]["points"].size(), 2, "左段 2 点")
	assert_eq(_layer.strokes[1]["points"].size(), 2, "右段 2 点")

	_layer.undo()
	assert_eq(_layer.strokes.size(), 1, "撤销应恢复为完整一笔")
	assert_eq(_layer.strokes[0]["points"].size(), 5, "撤销后点数复原")


# D11：局部擦除的重做 —— 再次切回两段
func test_d11_partial_erase_redo() -> void:
	_layer.erase_mode = DrawingLayer.EraseMode.PARTIAL
	_draw_five_point_line()
	_layer._start_erase()
	_layer._erase_at(Vector2(20, 0))
	_layer._finish_erase()
	_layer.undo()
	_layer.redo()
	assert_eq(_layer.strokes.size(), 2, "重做后应回到两段")


# D12：整条模式行为不被新功能改变 —— 命中任意一点即删整笔
func test_d12_whole_erase_removes_full_stroke() -> void:
	_layer.erase_mode = DrawingLayer.EraseMode.WHOLE
	_draw_five_point_line()
	_layer._start_erase()
	_layer._erase_at(Vector2(10, 0))
	_layer._finish_erase()
	assert_eq(_layer.strokes.size(), 0, "整条模式：命中中间点即删整笔")
	_layer.undo()
	assert_eq(_layer.strokes.size(), 1, "撤销应恢复原笔")
	assert_eq(_layer.strokes[0]["points"].size(), 5)
