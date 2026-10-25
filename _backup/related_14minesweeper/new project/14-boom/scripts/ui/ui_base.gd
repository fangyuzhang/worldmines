extends Control
## 主界面：在 ui_base 场景骨架上挂接完整游戏内容。
## - Menu/VariantSection：变体选择列表（A/B 类 checkbox）+ 预设 + 难度 + 开始
## - GameUI/HUD：计时器 / 插旗计数 / 变体名 / 重新开始
## - GameUI/BoardArea：棋盘视图（board_view）
## - GameUI/SidePanel：状态提示 + 我的进度
## - GameOver：结算覆盖层（胜负文本 / 统计 / 星级 / 再来一局 / 返回菜单）
## 全部色块占位，无美术资源。

const BoardViewScript := preload("res://scripts/ui/board_view.gd")

# 预设组合包（GDD §4.3）
const PRESETS := {
	"经典": [[], ["classic"]],
	"休闲": [["RF"], ["4N", "Clock"]],
	"平衡": [["MX"], ["classic", "4N"]],
	"硬核": [["DT"], ["4N", "SC", "HaloDiff", "LoopRuns"]],
}

var _gen_checks: Dictionary = {}
var _num_checks: Dictionary = {}
var _board_view: Control
var _controller: GameController
var _score_label: Label
var _menu_hint: Label
var _status_label: Label
var _stats_label: Label
var _difficulty_option: OptionButton
# HUD
var _time_label: Label
var _flag_label: Label
var _variant_label: Label
var _restart_btn_hud: Button
# 结算
var _over_text: Label
var _over_stats: Label
var _restart_btn: Button
var _menu_btn: Button
var _game_over_shown := false

func _ready() -> void:
	_build_variant_section()
	_build_hud()
	_build_board_area()
	_build_side_panel()
	_build_game_over()
	# 默认勾选经典
	if _num_checks.has("classic"):
		_num_checks["classic"].button_pressed = true
	_update_score()
	_update_stats()
	show_menu()
	_run_self_check()

## 场景静态布局：Menu 用 VBox 排列、GameUI 铺满、GameOver 铺满
func _setup_layout() -> void:
	var menu := get_node_or_null("Menu")
	if menu:
		menu.set_anchors_preset(Control.PRESET_FULL_RECT)
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		box.add_theme_constant_override("separation", 12)
		menu.add_child(box)
		for child in menu.get_children():
			if child != box:
				menu.remove_child(child)
				box.add_child(child)
	var gui := get_node_or_null("GameUI")
	if gui:
		gui.set_anchors_preset(Control.PRESET_FULL_RECT)
	var over := get_node_or_null("GameOver")
	if over:
		over.set_anchors_preset(Control.PRESET_FULL_RECT)

# ================= 各区域构建 =================

## Menu/VariantSection：变体选择列表
func _build_variant_section() -> void:
	var section := get_node_or_null("Menu/VariantSection")
	if section == null:
		return
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	section.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)

	_menu_hint = Label.new()
	_menu_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_menu_hint.add_theme_color_override("font_color", Color("#ffb74d"))
	box.add_child(_menu_hint)

	_add_section_label(box, "生成层变体（A 类 · 雷怎么放）")
	var gen_box := VBoxContainer.new()
	gen_box.add_theme_constant_override("separation", 2)
	box.add_child(gen_box)
	for v in VariantRegistry.generation_variants():
		_gen_checks[v.id] = _make_variant_checkbox(v, gen_box)

	_add_section_label(box, "数字规则变体（B 类 · 数字怎么算）")
	var num_box := VBoxContainer.new()
	num_box.add_theme_constant_override("separation", 2)
	box.add_child(num_box)
	for v in VariantRegistry.number_variants():
		_num_checks[v.id] = _make_variant_checkbox(v, num_box)

	_score_label = Label.new()
	_score_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_score_label)

	_add_section_label(box, "预设组合包")
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 6)
	box.add_child(preset_row)
	for preset_name in PRESETS.keys():
		var btn := Button.new()
		btn.text = preset_name
		btn.pressed.connect(_apply_preset.bind(preset_name))
		preset_row.add_child(btn)

	_add_section_label(box, "难度")
	_difficulty_option = OptionButton.new()
	for diff in ["简单 9×9 / 10", "中等 16×16 / 40", "困难 16×30 / 99"]:
		_difficulty_option.add_item(diff)
	box.add_child(_difficulty_option)
	_refresh_difficulty_unlock()

	var start_btn := Button.new()
	start_btn.text = "开始游戏"
	start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_btn.pressed.connect(_start_game)
	box.add_child(start_btn)

	for cb in _gen_checks.values():
		cb.toggled.connect(_on_toggled)
	for cb in _num_checks.values():
		cb.toggled.connect(_on_toggled)

## GameUI/HUD：顶栏
func _build_hud() -> void:
	var hud := get_node_or_null("GameUI/HUD")
	if hud == null:
		return
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 16)
	hud.add_child(row)

	_time_label = Label.new()
	_time_label.text = "⏱ 0.0s"
	row.add_child(_time_label)
	_flag_label = Label.new()
	_flag_label.text = "🚩 0/10"
	row.add_child(_flag_label)
	_variant_label = Label.new()
	_variant_label.text = "未开始"
	_variant_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_variant_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_variant_label)
	_restart_btn_hud = Button.new()
	_restart_btn_hud.text = "重新开始"
	_restart_btn_hud.pressed.connect(_start_game)
	row.add_child(_restart_btn_hud)

## GameUI/BoardArea：棋盘
func _build_board_area() -> void:
	var area := get_node_or_null("GameUI/BoardArea")
	if area == null:
		return
	_board_view = BoardViewScript.new()
	_board_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	area.add_child(_board_view)

## GameUI/SidePanel：状态 + 进度
func _build_side_panel() -> void:
	var panel := get_node_or_null("GameUI/SidePanel")
	if panel == null:
		return
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	_add_section_label(box, "对局状态")
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status_label)

	_add_section_label(box, "我的进度")
	_stats_label = Label.new()
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_stats_label)

## GameOver：结算面板
func _build_game_over() -> void:
	var over := get_node_or_null("GameOver")
	if over == null:
		return
	over.color = Color(0, 0, 0, 0.78)
	over.visible = false
	var center := VBoxContainer.new()
	center.set_anchors_preset(Control.PRESET_CENTER)
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 16)
	over.add_child(center)

	_over_text = Label.new()
	_over_text.add_theme_font_size_override("font_size", 36)
	_over_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(_over_text)

	_over_stats = Label.new()
	_over_stats.add_theme_font_size_override("font_size", 16)
	_over_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(_over_stats)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	center.add_child(btn_row)
	_restart_btn = Button.new()
	_restart_btn.text = "再来一局"
	_restart_btn.pressed.connect(_start_game)
	btn_row.add_child(_restart_btn)
	_menu_btn = Button.new()
	_menu_btn.text = "返回菜单"
	_menu_btn.pressed.connect(show_menu)
	btn_row.add_child(_menu_btn)

# ================= 页面切换 =================

func show_menu() -> void:
	$Menu.visible = true
	$GameUI.visible = false
	$GameOver.visible = false

func show_game() -> void:
	$Menu.visible = false
	$GameUI.visible = true
	$GameOver.visible = false

func show_game_over(won: bool) -> void:
	$GameOver.visible = true
	$GameOver.color = Color("#0097a7") if won else Color("#d32f2f")

# ================= 变体选择辅助 =================

func _add_section_label(box: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color("#7c4dff"))
	box.add_child(l)

func _make_variant_checkbox(v: VariantBase, box: VBoxContainer) -> CheckBox:
	var cb := CheckBox.new()
	var locked := not SaveManager.is_variant_unlocked(v.id)
	var lock := " 🔒" if locked else ""
	cb.text = "%s %s  ★%s  兼容%d/10%s" % [
		v.id, v.display_name, v.difficulty, int(v.compat_score), lock]
	cb.disabled = locked
	cb.tooltip_text = "未解锁（累计胜利 %d 局后解锁）" % _unlock_wins_for(v.id) if locked else v.display_name
	box.add_child(cb)
	return cb

func _unlock_wins_for(id: String) -> int:
	for tier in SaveManager.VARIANT_UNLOCKS:
		var t: Dictionary = tier as Dictionary
		if (t["ids"] as Array).has(id):
			return int(t["wins"])
	return 0

func _selected_ids(checks: Dictionary) -> Array:
	var ids: Array = []
	for id_str in checks.keys():
		if checks[id_str].button_pressed:
			ids.append(id_str)
	return ids

func _on_toggled(_pressed: bool) -> void:
	_update_score()

func _update_score() -> void:
	if _score_label == null:
		return
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
	_set_menu_hint("")
	_update_score()

func _apply_ids(checks: Dictionary, ids: Array) -> void:
	for id_str in checks.keys():
		checks[id_str].button_pressed = ids.has(id_str)

func _set_menu_hint(text: String) -> void:
	if _menu_hint == null:
		return
	_menu_hint.text = text

# ================= 对局控制 =================

## 开始游戏：先校验，校验失败留在菜单并提示，不切到对局界面
func _start_game() -> void:
	_game_over_shown = false
	var gen_ids := _selected_ids(_gen_checks)
	var num_ids := _selected_ids(_num_checks)
	if num_ids.is_empty():
		_set_menu_hint("⚠ 请至少选择 1 个 B 类（数字规则）变体。")
		return
	if not SaveManager.is_difficulty_unlocked(_difficulty_option.selected):
		_set_menu_hint("⚠ 该难度尚未解锁，请先在更低难度累计胜利。")
		return
	var rows := 9
	var cols := 9
	var mines := 10
	match _difficulty_option.selected:
		1: rows = 16; cols = 16; mines = 40
		2: rows = 16; cols = 30; mines = 99
	var ctrl := GameController.new(rows, cols, mines, gen_ids, num_ids)
	if not ctrl.is_ready():
		_set_menu_hint("⚠ 该组合无法生成有效棋盘（无解概率过高），请调整变体组合。")
		return
	_controller = ctrl
	_set_menu_hint("")
	show_game()
	_board_view.set_controller(_controller)
	SaveManager.start_play_session()
	_variant_label.text = "%s + %s" % [", ".join(gen_ids) if gen_ids else "经典雷阵", ", ".join(num_ids)]
	_flag_label.text = "🚩 0/%d" % mines
	_time_label.text = "⏱ 0.0s"
	_status_label.text = "已选择：[%s] + [%s]  （R 键重新开始）" % [", ".join(gen_ids), ", ".join(num_ids)]
	_board_view.queue_redraw()

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_R and _controller != null:
		_start_game()

func _process(_delta: float) -> void:
	if _controller == null:
		return
	if _controller.status == GameController.Status.PLAYING:
		_controller.update_timer()
		_time_label.text = "⏱ %.1fs" % _controller.elapsed
		_flag_label.text = "🚩 %d/%d" % [_controller.flag_count(), _controller.mine_count]
	if not _game_over_shown:
		if _controller.status == GameController.Status.WON:
			_show_game_over(true)
		elif _controller.status == GameController.Status.LOST:
			_show_game_over(false)

func _show_game_over(won: bool) -> void:
	show_game_over(won)
	if won:
		_over_text.text = "🎉 胜利！"
		_over_text.add_theme_color_override("font_color", Color("#81c784"))
	else:
		_over_text.text = "💥 失败了"
		_over_text.add_theme_color_override("font_color", Color("#e57373"))
	SaveManager.record_game(won, _difficulty_option.selected, _controller.elapsed, _selected_ids(_gen_checks) + _selected_ids(_num_checks))
	var stars := ""
	if won:
		var base_time := 60.0 * (float(_difficulty_option.selected) + 1.0)
		var t := _controller.elapsed
		stars = "⭐⭐⭐" if t <= base_time else ("⭐⭐" if t <= base_time * 2.5 else "⭐")
	_over_stats.text = "用时：%.1f 秒\n点击：%d 次    插旗：%d 次%s" % [
		_controller.elapsed, _controller.click_count, _controller.flag_actions,
		("\n\n评价：%s" % stars) if won else ""]
	_board_view.queue_redraw()
	_refresh_difficulty_unlock()
	for v in VariantRegistry.all_variants():
		if _gen_checks.has(v.id):
			_gen_checks[v.id].disabled = not SaveManager.is_variant_unlocked(v.id)
		if _num_checks.has(v.id):
			_num_checks[v.id].disabled = not SaveManager.is_variant_unlocked(v.id)
	_game_over_shown = true
	_update_stats()

func _refresh_difficulty_unlock() -> void:
	if _difficulty_option == null:
		return
	for i in range(3):
		var unlocked := SaveManager.is_difficulty_unlocked(i)
		var cur := _difficulty_option.get_item_text(i)
		if not unlocked and not cur.contains("🔒"):
			_difficulty_option.set_item_text(i, cur + " 🔒")

func _update_stats() -> void:
	if _stats_label == null:
		return
	var d: Dictionary = SaveManager.data
	var prog: Dictionary = d.progress
	var wins: int = int(prog.total_wins)
	var games: int = int(prog.total_games)
	var winrate := 0.0
	if games > 0:
		winrate = float(wins) * 100.0 / float(games)
	var unlocked_count := _unlocked_variant_count()
	_stats_label.text = "总局数：%d    胜率：%.0f%%\n胜利：%d    连胜：%d (最高 %d)\n已解锁变体：%d / %d\n总时长：%d 秒" % [
		games, winrate, wins, int(prog.win_streak), int(prog.best_streak),
		unlocked_count, VariantRegistry.variant_count(), int(prog.total_play_time_seconds)]

func _unlocked_variant_count() -> int:
	var n := 0
	for v in VariantRegistry.all_variants():
		if SaveManager.is_variant_unlocked(v.id):
			n += 1
	return n

# ================= 框架自检 =================

func _run_self_check() -> void:
	print("========== MineVariant 框架自检 ==========")
	print("[1] 已注册变体 (%d):" % VariantRegistry.variant_count())
	for v in VariantRegistry.all_variants():
		var cat := "生成层A" if v.category == VariantBase.Category.GENERATION else "数字规则B"
		print("    %-7s %-6s %s  兼容%.0f/10" % [v.id, cat, v.display_name, v.compat_score])
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	print("[2] A 类生成约束验证（9x9/10雷）:")
	for v in VariantRegistry.generation_variants():
		var vb: VariantBase = v as VariantBase
		var gen := BoardGenerator.new([vb])
		var b := gen.generate(9, 9, 10, rng)
		var ok: bool = b != null and vb.check_constraints(b)
		print("    %-9s 生成成功: %s（约束满足: %s）" % [vb.id, b != null, ok])
	print("[3] 冲突检测:")
	for combo in [["MX", "RF"], ["4N", "Clock"], ["MX", "4N"], ["classic", "HV"]]:
		var res := ConflictChecker.score(combo)
		print("    %-14s → 评分 %.1f  [%s] %s" % [", ".join(combo), res.score, res.level, res.desc])
	print("[4] B 类叠加显示（classic + 4N）:")
	var gc := GameController.new(9, 9, 10, [], ["classic", "4N"])
	if gc.is_ready():
		print("    混合对局生成成功 ✓（格子上会同时显示两个数字）")
	print("========== 自检结束 ==========")
