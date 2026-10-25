extends GutTest
## hint_panel.gd 盲区补测（2026-10-25；326 行 UI 组件此前零直接测试）。
## 测：显示/清空契约、无痕↔唤醒切换（穿透语义）、坐标 1-based、字体钳制、几何下限。

const ReasoningStepScript := preload("res://core/reasoning_step.gd")

var _font_backup: int
var _size_backup: Vector2
var _pos_backup: Vector2


func before_all() -> void:
	_font_backup = SettingsManager.hint_font_size
	_size_backup = SettingsManager.hint_window_size
	_pos_backup = SettingsManager.hint_window_pos


func after_all() -> void:
	SettingsManager.set_hint_font_size(_font_backup)
	SettingsManager.set_hint_window_size(_size_backup)
	SettingsManager.set_hint_window_pos(_pos_backup)


func _make_panel() -> HintPanel:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	add_child_autofree(host)
	var p := HintPanel.new()
	host.add_child(p)
	return p


func test_initially_hidden() -> void:
	var p := _make_panel()
	assert_false(p.visible, "首次有提示前应隐藏")


func test_show_empty_hint_gives_guidance() -> void:
	var p := _make_panel()
	p.show_hint([])
	assert_true(p.visible, "空提示也应可见（展示引导文案）")
	assert_true(p._content.text.contains("没有 100% 必然可推的一步"), "空提示给详细引导")


func test_show_steps_renders_one_based_coords() -> void:
	var p := _make_panel()
	var s1 := ReasoningStepScript.new()
	s1.pos = Vector2i(2, 0)   # x=列2, y=行0 → 玩家视角 (1,3)
	s1.state = "safe"
	s1.tier = "step"
	s1.proof = "由 0 格扩散"
	var s2 := ReasoningStepScript.new()
	s2.pos = Vector2i(4, 5)
	s2.state = "mine"
	s2.tier = "step"
	s2.proof = "数字 1 已满"
	p.show_hint([s1, s2])
	var txt: String = p._content.text
	assert_true(txt.contains("■ 安全"), "安全结论渲染")
	assert_true(txt.contains("(1,3)"), "坐标 1-based（行,列）")
	assert_true(txt.contains("■ 雷"), "雷结论渲染")
	assert_true(txt.contains("(6,5)"), "第二个坐标 1-based")
	assert_true(txt.contains("当前可 100% 确定"), "step 档标题")


func test_region_tier_skips_cell_lines() -> void:
	var p := _make_panel()
	var r := ReasoningStepScript.new()
	r.pos = Vector2i(1, 1)
	r.tier = "region"
	r.proof = "区域圈选"
	p.show_hint([r])
	assert_true(p._content.text.contains("先看这些可疑区域"), "region 档给观察引导")
	assert_false(p._content.text.contains("■"), "region 档不替玩家判雷/安全（不出现结论行）")


func test_clear_hint() -> void:
	var p := _make_panel()
	p.show_hint([])
	p.clear_hint()
	assert_false(p.visible, "清空后隐藏")
	assert_eq(p._content.text, "", "清空内容")


func test_ghost_vs_awake_semantics() -> void:
	var p := _make_panel()
	# 无痕态（默认/每次新提示）：chrome 隐藏 + 文字穿透（点击落到棋盘）
	p.show_hint([])
	assert_true(p._ghost, "新提示从无痕态开始")
	assert_false(p._title_bar.visible, "无痕隐藏标题栏")
	assert_false(p._toolbar.visible, "无痕隐藏工具栏")
	assert_eq(p._content.mouse_filter, Control.MOUSE_FILTER_IGNORE, "无痕态文字穿透")
	assert_true(p._ghost_grip.visible, "无痕态保留顶部唤醒热区")
	# 唤醒态：chrome 显示 + 文字可选中
	p._set_ghost(false)
	assert_true(p._title_bar.visible, "唤醒显示标题栏")
	assert_true(p._resize_handle.visible, "唤醒显示缩放手柄")
	assert_eq(p._content.mouse_filter, Control.MOUSE_FILTER_STOP, "唤醒态文字可选中复制")


func test_font_adjust_clamps_and_persists() -> void:
	var p := _make_panel()
	p._font_size = HintPanel.MAX_FONT - 1
	p._adjust_font(2)
	assert_eq(p._font_size, HintPanel.MAX_FONT, "上调钳到 MAX_FONT")
	assert_eq(SettingsManager.hint_font_size, HintPanel.MAX_FONT, "字号经 SettingsManager 持久化")
	p._font_size = HintPanel.MIN_FONT + 1
	p._adjust_font(-2)
	assert_eq(p._font_size, HintPanel.MIN_FONT, "下调钳到 MIN_FONT")


func test_geometry_floor_is_min_size() -> void:
	SettingsManager.set_hint_window_size(Vector2(10, 10))
	var p := _make_panel()
	assert_gte(p.size.x, HintPanel.MIN_SIZE.x, "窗口宽下限")
	assert_gte(p.size.y, HintPanel.MIN_SIZE.y, "窗口高下限")


func test_hex_format() -> void:
	var p := _make_panel()
	assert_eq(p._hex(Color(1.0, 0.5, 0.0)), "#ff7f00", "颜色转 bbcode hex（int 截断：0.5*255=127=0x7f）")
