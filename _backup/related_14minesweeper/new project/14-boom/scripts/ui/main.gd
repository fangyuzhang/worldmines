extends Control
## 主场景：左侧变体选择（从 VariantRegistry 动态生成），右侧棋盘。
## 顶部 HUD：计时器 + 插旗计数 + 变体名；胜利/失败覆盖层（GDD §8.4/§8.5）。
## 验证核心能力：新增一个变体模块 → 注册表自动注册 → UI 自动出现勾选项 → 直接参与混合对局。

const BoardViewScript := preload("res://scripts/ui/board_view.gd")

# 预设组合包（GDD §4.3）
const PRESETS := {
	"经典": [[], ["classic"]],
	"休闲": [["RF"], ["4N", "Clock"]],
	"平衡": [["MX"], ["classic", "4N"]],
	"硬核": [["DT"], ["4N", "SC", "HaloDiff", "LoopRuns"]],
}

var _gen_checks: Dictionary = {}   # id -> CheckBox
var _num_checks: Dictionary = {}
var _board_view: Control
var _controller: GameController
var _score_label: Label
var _status_label: Label
var _difficulty_option: OptionButton
# HUD
var _time_label: Label
var _flag_label: Label
var _variant_label: Label
var _game_over: ColorRect        # 胜负覆盖层
var _over_text: Label
var _over_stats: Label
var _restart_btn: Button
var _menu_btn: Button
var _restart_btn_hud: Button
# 进度统计
var _stats_label: Label
var _game_over_shown := false   # 本局是否已弹出过结算（防 _process 每帧重复记录）

func _ready() -> void:
	_build_ui()
	_update_score()
	_update_stats()
	_run_self_check()

## 框架自检：验证「注册 → A类生成约束 → 冲突检测」全链路，结果打印到控制台。
## 打开本场景即可在输出面板看到结果。
func _run_self_check() -> void:
	print("========== MineVariant 框架自检 ==========")
	print("[1] 已注册变体 (%d):" % VariantRegistry.variant_count())
	for v in VariantRegistry.all_variants():
		var cat := "生成层A" if v.category == VariantBase.Category.GENERATION else "数字规则B"
		print("    %-7s %-6s %s  兼容%.0f/10" % [v.id, cat, v.display_name, v.compat_score])

	# [2] 全部 A 类变体生成验证（定向生成优先，拒绝采样兜底）
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	print("[2] A 类生成约束验证（9x9/10雷）:")
	for v in VariantRegistry.generation_variants():
		var vb: VariantBase = v as VariantBase
		var gen := BoardGenerator.new([vb])
		var b := gen.generate(9, 9, 10, rng)
		var ok: bool = b != null and vb.check_constraints(b)
		print("    %-9s 生成成功: %s（约束满足: %s）" % [vb.id, b != null, ok])

	# [3] 冲突检测（含强冲突组合）
	print("[3] 冲突检测:")
	for combo in [["MX", "RF"], ["4N", "Clock"], ["MX", "4N"], ["classic", "HV"]]:
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
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	# ===== 顶部 HUD（GDD §8.4）=====
	var hud := HBoxContainer.new()
	hud.add_theme_constant_override("separation", 16)
	root.add_child(hud)
	_time_label = Label.new()
	_time_label.text = "⏱ 0.0s"
	hud.add_child(_time_label)
	_flag_label = Label.new()
	_flag_label.text = "🚩 0/10"
	hud.add_child(_flag_label)
	_variant_label = Label.new()
	_variant_label.text = "未开始"
	_variant_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_variant_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hud.add_child(_variant_label)
	_restart_btn_hud = Button.new()
	_restart_btn_hud.text = "重新开始"
	_restart_btn_hud.pressed.connect(_start_game)
	hud.add_child(_restart_btn_hud)

	# ===== 主体 =====
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	root.add_child(body)

	# ===== 左面板 =====
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(300, 0)
	body.add_child(left)
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

	# --- 我的进度（GDD §5.3.1）---
	_add_section_label(left_box, "我的进度")
	_stats_label = Label.new()
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left_box.add_child(_stats_label)

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
	# 难度解锁状态刷新
	_refresh_difficulty_unlock()

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
	body.add_child(right)

	_status_label = Label.new()
	_status_label.text = "选择变体后点击「开始游戏」。"
	right.add_child(_status_label)

	_board_view = BoardViewScript.new()
	_board_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_board_view)

	# ===== 胜负覆盖层（GDD §8.5）=====
	_game_over = ColorRect.new()
	_game_over.color = Color(0, 0, 0, 0.78)
	_game_over.set_anchors_preset(Control.PRESET_FULL_RECT)
	_game_over.mouse_filter = Control.MOUSE_FILTER_STOP
	_game_over.visible = false
	add_child(_game_over)
	var over_center := VBoxContainer.new()
	over_center.set_anchors_preset(Control.PRESET_CENTER)
	over_center.alignment = BoxContainer.ALIGNMENT_CENTER
	_game_over.add_child(over_center)
	_over_text = Label.new()
	_over_text.add_theme_font_size_override("font_size", 36)
	_over_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_center.add_child(_over_text)
	_over_stats = Label.new()
	_over_stats.add_theme_font_size_override("font_size", 16)
	_over_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_center.add_child(_over_stats)
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	over_center.add_child(btn_row)
	_restart_btn = Button.new()
	_restart_btn.text = "再来一局"
	_restart_btn.pressed.connect(_start_game)
	btn_row.add_child(_restart_btn)
	_menu_btn = Button.new()
	_menu_btn.text = "返回菜单"
	_menu_btn.pressed.connect(_hide_game_over)
	btn_row.add_child(_menu_btn)

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
	_hide_game_over()
	_game_over_shown = false
	var gen_ids := _selected_ids(_gen_checks)
	var num_ids := _selected_ids(_num_checks)
	if num_ids.is_empty():
		_status_label.text = "请至少选择 1 个 B 类（数字规则）变体。"
		return
	if not SaveManager.is_difficulty_unlocked(_difficulty_option.selected):
		_status_label.text = "该难度尚未解锁，请先在更低难度累计胜利。"
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
	SaveManager.start_play_session()
	_variant_label.text = "%s + %s" % [", ".join(gen_ids) if gen_ids else "经典雷阵", ", ".join(num_ids)]
	_flag_label.text = "🚩 0/%d" % mines
	_time_label.text = "⏱ 0.0s"
	_status_label.text = "已选择：[%s] + [%s]  （R 键重新开始）" % [", ".join(gen_ids), ", ".join(num_ids)]
	_board_view.queue_redraw()

func _hide_game_over() -> void:
	_game_over.visible = false

func _unhandled_key_input(event: InputEvent) -> void:
	# R 键重新开始（GDD §2.2.2）
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_R and _controller != null:
		_start_game()

func _process(_delta: float) -> void:
	if _controller == null:
		return
	# 刷新 HUD
	if _controller.status == GameController.Status.PLAYING:
		_controller.update_timer()
		_time_label.text = "⏱ %.1fs" % _controller.elapsed
		_flag_label.text = "🚩 %d/%d" % [_controller.flag_count(), _controller.mine_count]
	# 胜负（只弹一次）
	if not _game_over_shown:
		if _controller.status == GameController.Status.WON:
			_show_game_over(true)
		elif _controller.status == GameController.Status.LOST:
			_show_game_over(false)

func _show_game_over(won: bool) -> void:
	_game_over.visible = true
	if won:
		_over_text.text = "🎉 胜利！"
		_over_text.add_theme_color_override("font_color", Color("#81c784"))
	else:
		_over_text.text = "💥 失败了"
		_over_text.add_theme_color_override("font_color", Color("#e57373"))
	# 记录统计（GDD §5.3 + §2.4）
	SaveManager.record_game(won, _difficulty_option.selected, _controller.elapsed, _selected_ids(_gen_checks) + _selected_ids(_num_checks))
	# 星级评价（§8.5.1）：胜利按用时评星
	var stars := ""
	if won:
		var base_time := 60.0 * (float(_difficulty_option.selected) + 1.0)
		var t := _controller.elapsed
		stars = "⭐⭐⭐" if t <= base_time else ("⭐⭐" if t <= base_time * 2.5 else "⭐")
	_over_stats.text = "用时：%.1f 秒\n点击：%d 次    插旗：%d 次%s" % [
		_controller.elapsed, _controller.click_count, _controller.flag_actions,
		("\n\n评价：%s" % stars) if won else ""]
	_board_view.queue_redraw()
	# 刷新解锁状态（可能新解锁了变体/难度）
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
		var locked := not unlocked
		var cur := _difficulty_option.get_item_text(i)
		if locked and not cur.contains("🔒"):
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
