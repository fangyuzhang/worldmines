# test_drawing_toolbar.gd —— 底栏绘画工具栏
# 验证：可随绘画层构建并完成 setup、新增的擦除模式按钮可切换、绘画层与工具栏双向同步。
extends GutTest

var _layer: DrawingLayer
var _tb


func before_each() -> void:
	_layer = load("res://ui/drawing_layer.tscn").instantiate()
	add_child_autofree(_layer)
	_tb = load("res://ui/drawing_toolbar.tscn").instantiate()
	add_child_autofree(_tb)
	_tb.setup(_layer)


## 在工具栏子树里按文本递归查找按钮
func _find_button(text: String) -> Button:
	return _find_button_in(_tb, text)


func _find_button_in(n: Node, text: String) -> Button:
	if n is Button and n.text == text:
		return n
	for c in n.get_children():
		var r: Button = _find_button_in(c, text)
		if r != null:
			return r
	return null


# T1：工具栏可构建并完成 setup（含新增的擦除模式按钮）
func test_t1_builds_and_setups() -> void:
	assert_not_null(_tb, "工具栏应能实例化")
	assert_not_null(_find_button("绘画"), "应有绘画开关按钮")
	assert_not_null(_find_button("清空绘画"), "应有清空按钮")
	assert_not_null(_find_button("擦整条"), "默认应为整条擦除模式")


# T2：按下擦除模式按钮 → 绘画层切到局部擦除 + 按钮文案同步
func test_t2_erase_mode_toggle_syncs() -> void:
	var btn := _find_button("擦整条")
	assert_not_null(btn, "初始文案应为「擦整条」")
	btn.set_pressed(true)
	assert_eq(_layer.erase_mode, DrawingLayer.EraseMode.PARTIAL,
			"按下后绘画层应切到局部擦除")
	assert_eq(btn.text, "擦局部", "按钮文案应同步为「擦局部」")


# T3：绘画层侧改模式 → 经 changed 信号让工具栏同步
func test_t3_refresh_follows_layer() -> void:
	_layer.erase_mode = DrawingLayer.EraseMode.PARTIAL
	_layer.changed.emit()
	assert_not_null(_find_button("擦局部"), "绘画层改模式后工具栏应同步")


# T4：绘画开关状态与绘画层双向同步
func test_t4_paint_mode_sync() -> void:
	_layer.set_paint_mode(true)
	assert_true(_find_button("绘画").button_pressed, "绘画按钮应呈按下态")
	_layer.set_paint_mode(false)
	assert_false(_find_button("绘画").button_pressed, "退出绘画后按钮应复位")
