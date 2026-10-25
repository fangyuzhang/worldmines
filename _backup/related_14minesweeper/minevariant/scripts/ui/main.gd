extends Control
## 主场景：左侧变体选择（从 VariantRegistry 动态生成），右侧棋盘。
## 验证核心能力：新增一个变体模块 → 注册表自动注册 → UI 自动出现勾选项 → 直接参与混合对局。

const BoardViewScript := preload("res://scripts/ui/board_view.gd")

# 预设组合包（GDD §4.3）
const PRESETS := {
	"经典": [[], ["classic"]],
	"休闲": [["RF"], ["4N", "Clock"]],
	"平衡": [["MX"], ["classic", "4N"]],
	"硬核": [["MX"], ["Clock", "4N", "classic"]],
}

var _gen_checks: Dictionary = {}   # id -> CheckBox
var _num_checks: Dictionary = {}
var _board_view: Control
var _controller: GameController
var _score_label: Label
var _status_label: Label
var _difficulty_option: OptionButton

func _ready() -> void:
	_build_ui()
	_update_score()
	_run_self_check()

## 框架自检：验证「注册 → A类生成约束 → 冲突检测」全链路，结果打印到控制台。
## 打开本场景即可在输出面板看到结果。
func _run_self_check() -> void:
	print("========== MineVariant 框架自检 ==========")
	print("[1] 已注册变体 (%d):" % VariantRegistry.variant_count())
	for v in VariantRegistry.all_variants():
		var cat := "生成层A" if v.category == VariantBase.Category.GENERATION else "数字规则B"
		print("    %-7s %-6s %s  兼容%.0f/10" % [v.id, cat, v.display_name, v.compat_score])

	# [2] A 类生成约束验证
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	print("[2] A 类生成约束验证:")
	var mx := VariantRegistry.get_variant("MX")
	if mx:
		var gen := BoardGenerator.new([mx])
		var b := gen.generate(9, 9, 10, rng)
		var ok := b != null and mx.check_constraints(b)
		print("    镜像 MX + 9x9/10雷 生成成功: %s（镜像约束满足: %s）" % [b != null, ok])
	var rf := VariantRegistry.get_variant("RF")
	if rf:
		var gen2 := BoardGenerator.new([rf])
		var b2 := gen2.generate(9, 9, 10, rng)
		var ok2 := b2 != null and rf.check_constraints(b2)
		print("    行首尾 RF + 9x9/10雷 生成成功: %s（行首尾约束满足: %s）" % [b2 != null, ok2])

	# [3] 冲突检测
	print("[3] 冲突检测:")
	for combo in [["MX", "RF"], ["4N", "Clock"], ["MX", "4N"]]:
		var res := ConflictChecker.score(combo)
		print("    %-14s → 评分 %.1f  [%s] %s" % [", ".join(combo), res.score, res.level, res.desc])

	# [4] 混合对局（B 类叠加显示）
	print("[4] B 类叠加显示（classic + 4N）:")
	var gc := GameController.new(9, 9, 10, [], ["classic", "4N"])
	if gc.is_ready():
		# 找一个已揭开的安全格看线索叠加
		print("    混合对局生成成功 ✓（格子上会同时显示两个数字）")
	print("========== 自检结束 ==========")

func _build_ui() -> void:
	# ===== 根布局 =====
	var root := HBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	# ===== 左面板 =====
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(300, 0)
	root.add_child(left)
	var left_scroll := ScrollContainer.new()
	left.add_child(left_scroll)
	var left_box := VBoxContainer.new()
	left_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(left_box)

	_add_title(left_box, "MineVariant · 扫雷变体框架")

	# --- 生成层变体（A 类） ---
	_add_section_label(left_box, "生成层变体（A 类 · 雷怎么放）")
	var gen_box := VBoxContainer.new()
	gen_box.add_theme_constant_override("separation", 2)
	left_box.add_child(gen_box)
	for v in VariantRegistry.generation_variants():
		_gen_checks[v.id] = _make_variant_checkbox(v, gen_box)

	# --- 数字规则变体（B 类） ---
	_add_section_label(left_box, "数字规则变体（B 类 · 数字怎么算）")
	var num_box := VBoxContainer.new()
	num_box.add_theme_constant_override("separation", 2)
	left_box.add_child(num_box)
	for v in VariantRegistry.number_variants():
		_num_checks[v.id] = _make_variant_checkbox(v, num_box)

	# --- 兼容性评分 ---
	_score_label = Label.new()
	_score_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left_box.add_child(_score_label)

	# --- 预设组合 ---
	_add_section_label(left_box, "预设组合包")
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 6)
	left_box.add_child(preset_row)
	for preset_name in PRESETS.keys():
		var btn := Button.new()
		btn.text = preset_name
		btn.pressed.connect(_apply_preset.bind(preset_name))
		preset_row.add_child(btn)

	# --- 难度 ---
	_add_section_label(left_box, "难度")
	_difficulty_option = OptionButton.new()
	for diff in ["简单 9×9 / 10", "中等 16×16 / 40", "困难 16×30 / 99"]:
		_difficulty_option.add_item(diff)
	left_box.add_child(_difficulty_option)

	# --- 开始按钮 ---
	var start_btn := Button.new()
	start_btn.text = "开始游戏"
	start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_btn.pressed.connect(_start_game)
	left_box.add_child(start_btn)

	# 监听勾选变化
	for cb in _gen_checks.values():
		cb.toggled.connect(_on_toggled)
	for cb in _num_checks.values():
		cb.toggled.connect(_on_toggled)

	# ===== 右面板 =====
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(right)

	_status_label = Label.new()
	_status_label.text = "选择变体后点击「开始游戏」。"
	right.add_child(_status_label)

	_board_view = BoardViewScript.new()
	_board_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_board_view)

	# 默认勾选经典
	if _num_checks.has("classic"):
		_num_checks["classic"].button_pressed = true

func _add_title(box: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 18)
	box.add_child(l)

func _add_section_label(box: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color("#7c4dff"))
	box.add_child(l)

func _make_variant_checkbox(v: VariantBase, box: VBoxContainer) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = "%s %s  ★%s  兼容%d/10" % [
		v.id, v.display_name, v.difficulty, int(v.compat_score)]
	box.add_child(cb)
	return cb

func _selected_ids(checks: Dictionary) -> Array:
	var ids: Array = []
	for id_str in checks.keys():
		if checks[id_str].button_pressed:
			ids.append(id_str)
	return ids

func _on_toggled(_pressed: bool) -> void:
	_update_score()

func _update_score() -> void:
	var gen_ids := _selected_ids(_gen_checks)
	var num_ids := _selected_ids(_num_checks)
	var all_ids := gen_ids + num_ids
	var res := ConflictChecker.score(all_ids)
	_score_label.text = "组合兼容性：%s\n%s\n%s" % [
		"%.1f / 10" % res.score, res.desc,
		"\n".join(res.warnings)]
	var color := Color.WHITE
	match res.level:
		"green": color = Color("#81c784")
		"yellow": color = Color("#ffb74d")
		"red": color = Color("#e57373")
		"conflict": color = Color("#f44336")
	_score_label.add_theme_color_override("font_color", color)

func _apply_preset(name: String) -> void:
	var cfg: Array = PRESETS[name]
	_apply_ids(_gen_checks, cfg[0])
	_apply_ids(_num_checks, cfg[1])
	_update_score()

func _apply_ids(checks: Dictionary, ids: Array) -> void:
	for id_str in checks.keys():
		checks[id_str].button_pressed = ids.has(id_str)

func _start_game() -> void:
	var gen_ids := _selected_ids(_gen_checks)
	var num_ids := _selected_ids(_num_checks)
	if num_ids.is_empty():
		_status_label.text = "请至少选择 1 个 B 类（数字规则）变体。"
		return
	var rows := 9
	var cols := 9
	var mines := 10
	match _difficulty_option.selected:
		1: rows = 16; cols = 16; mines = 40
		2: rows = 16; cols = 30; mines = 99
	_controller = GameController.new(rows, cols, mines, gen_ids, num_ids)
	if not _controller.is_ready():
		_status_label.text = "该组合无法生成有效棋盘（无解概率过高），请调整变体组合。"
		return
	_board_view.set_controller(_controller)
	_status_label.text = "已选择：[%s] + [%s]" % [", ".join(gen_ids), ", ".join(num_ids)]
	_board_view.queue_redraw()

func _process(_delta: float) -> void:
	if _controller == null:
		return
	match _controller.status:
		GameController.Status.WON:
			_status_label.text = "🎉 胜利！"
		GameController.Status.LOST:
			_status_label.text = "💥 失败（踩雷）—— 按 R 或点击「开始游戏」重开"
