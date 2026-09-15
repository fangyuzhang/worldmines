# ui_toast.gd —— 全屏轻量提示（统一入口）
#
# 背景：main_menu / level_select 各自实现了一份「Label + Timer 2 秒自动消失」，
# 两份代码逐字符重复，且行为已经开始分叉（一个贴顶部、一个贴底部）。
# 收敛成本极低，先抽出来，后续任何页面需要 toast 都走这里。
#
# 约定：不拦截鼠标（MOUSE_FILTER_IGNORE），2 秒自动消失，位置可指定。
# 静态入口：UiToast.popup(parent, msg)。
class_name UiToast
extends RefCounted

const DEFAULT_TTL := 2.0


## 弹出一条提示。返回创建的 Label（一般无需使用）。
## parent 必须已在场景树中（需要 SceneTree 计时器）。
## danger=true → 危险/错误色；false → 普通文本色。
static func popup(parent: Node, msg: String, danger: bool = true) -> Label:
	if parent == null or not parent.is_inside_tree():
		return null
	var lb := Label.new()
	lb.name = "Toast"
	lb.text = msg
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lb.add_theme_font_size_override("font_size", 18)
	lb.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	lb.offset_top = -72
	lb.offset_bottom = -40
	lb.offset_left = 32
	lb.offset_right = -32
	lb.custom_minimum_size = Vector2(0, 32)
	parent.add_child(lb)
	if ThemeManager != null:
		lb.add_theme_color_override("font_color",
				ThemeManager.danger() if danger else ThemeManager.text())
	# 定时器挂在 toast 自己身上：随它一起释放。
	# 不要写成 create_timer(n).timeout.connect(lambda 捕获 lb) —— 场景切换后 lb 先被释放，
	# 2 秒后定时器回调会报「Lambda capture ... was freed」（实测在 GUT 里复现）。
	var timer := Timer.new()
	timer.wait_time = DEFAULT_TTL
	timer.one_shot = true
	lb.add_child(timer)
	timer.timeout.connect(lb.queue_free)
	timer.start()
	return lb
