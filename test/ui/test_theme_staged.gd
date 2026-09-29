# test_theme_staged.gd —— 【2026-09-30】分层主题过渡的契约测试
#
# 用户需求：移除「以按钮为圆心的圆形波浪」换肤动画，改为整个棋盘平滑、
# 有层次地过渡到新主题 —— 几何（圆角/缝）先变，材质（描边/高光/垫板/影）跟上，
# 配色最后整体渐变，各阶段重叠连贯、无生硬跳变（学习 chain-lab.html 的
# 按属性分速 transition 思路）。
#
# 实现位置：ThemeManager._retarget → tween_method(_staged_step, 0→1)，
# 键按 _key_stage 分三层（STAGE_GEO [0,0.32] / STAGE_MAT [0.24,0.60] /
# STAGE_COLOR [0.50,1.0]，窗口重叠 0.08）。本文件用**注入进度**直接调
# _staged_step(p)（绕开真实时钟），逐段断言中间态。
#
# ⚠️ 本文件直接改 autoload 的 mode/_target/_active/_from，after_all 原样还原。
extends GutTest

var _saved: Dictionary = {}


func before_all() -> void:
	_saved = {
		"mode": ThemeManager.mode,
		"prev": ThemeManager.prev_mode,
		"target": ThemeManager._target,
		"active": ThemeManager._active,
		"from": ThemeManager._from,
	}


func after_all() -> void:
	if _saved.is_empty():
		return
	ThemeManager.mode = _saved["mode"]
	ThemeManager.prev_mode = _saved["prev"]
	ThemeManager._target = _saved["target"]
	ThemeManager._active = _saved["active"]
	ThemeManager._from = _saved["from"]
	ThemeManager._phase_t = 1.0


func after_each() -> void:
	ThemeManager._phase_t = 1.0


## 同步构造一次「from_mode → to_mode」过渡现场（不启 tween，纯数据）。
## 与 _retarget 同口径：两端都补形态键缺省值（键集变窄方向才有真实渐变终点）。
func _arm(from_mode: String, to_mode: String) -> void:
	ThemeManager.mode = to_mode
	ThemeManager.prev_mode = from_mode
	ThemeManager._target = ThemeManager._palette_for(to_mode)
	ThemeManager._inject_form_defaults(ThemeManager._target)
	ThemeManager._from = ThemeManager._palette_for(from_mode)
	ThemeManager._inject_form_defaults(ThemeManager._from)
	ThemeManager._active = ThemeManager._from.duplicate()
	var nf: Array = ThemeManager.numbers_for(from_mode)
	ThemeManager._nums_from = nf.duplicate()
	ThemeManager._phase_t = 0.0


# ============================ 1. 三段窗口的次序 ============================

func test_geometry_leads_material_leads_color() -> void:
	## cozy_salt → cozy_prism：棱镜带全套形态键（圆角 0.28 / 缝 0.07 / 玻璃描边），
	## 三段各自的中间态都能被精确观测。
	_arm("cozy_salt", "cozy_prism")
	# p=0.10（几何段中段）：圆角/缝应已离开旧值，配色必须仍是旧主题的。
	ThemeManager._staged_step(0.10)
	var act: Dictionary = ThemeManager._active
	var tgt: Dictionary = ThemeManager._target
	var frm: Dictionary = ThemeManager._from
	var rf: float = float(act["tile_radius_frac"])
	assert_true(rf > float(frm["tile_radius_frac"]) and rf < float(tgt["tile_radius_frac"]),
		"p=0.10：tile_radius_frac 应在 from→to 之间（实得 %.4f）" % rf)
	assert_eq(act["bg"], frm["bg"], "p=0.10：配色段未开始，bg 必须仍是旧主题色")
	assert_eq(act["tile_inset"], frm["tile_inset"], "p=0.10：材质段未开始，tile_inset 仍是旧值")

	# p=0.45（几何完成、材质段中段）：几何 = 新值，配色仍旧。
	ThemeManager._staged_step(0.45)
	act = ThemeManager._active
	assert_eq(float(act["tile_radius_frac"]), float(tgt["tile_radius_frac"]),
		"p=0.45：几何段已完成（圆角 = 新主题值）")
	assert_true(act["tile_inset"] != frm["tile_inset"] and act["tile_inset"] != tgt["tile_inset"],
		"p=0.45：材质段进行中（tile_inset 在中间态）")
	assert_eq(act["bg"], frm["bg"], "p=0.45：配色段（0.50 起）未开始，bg 仍是旧值")

	# p=0.75（材质完成、配色段中段）。
	ThemeManager._staged_step(0.75)
	act = ThemeManager._active
	assert_eq(act["tile_inset"], tgt["tile_inset"], "p=0.75：材质段完成")
	assert_true(act["bg"] != frm["bg"] and act["bg"] != tgt["bg"],
		"p=0.75：配色段进行中（bg 在中间态）")


func test_narrowing_direction_still_morphs_geometry() -> void:
	## 棱镜 → 海盐（键集变窄）：几何/材质段必须**渐变回缺省值**（0.106 / 透明），
	## 不允许憋到收口瞬间跳变 —— 这是「无生硬跳变」的另一半。
	_arm("cozy_prism", "cozy_salt")
	ThemeManager._staged_step(0.10)
	var rf: float = float(ThemeManager._active["tile_radius_frac"])
	assert_true(rf > 0.106 and rf < 0.28,
		"p=0.10：变窄方向圆角也应处于中间态（实得 %.4f）" % rf)
	ThemeManager._staged_step(1.0)
	assert_eq(float(ThemeManager._active["tile_radius_frac"]), 0.106,
		"p=1.0：圆角应精确落到缺省 0.106")


func test_final_step_lands_exactly_on_target() -> void:
	_arm("cozy_salt", "cozy_prism")
	ThemeManager._staged_step(1.0)
	var act: Dictionary = ThemeManager._active
	var tgt: Dictionary = ThemeManager._target
	for k in ["bg", "cell_hidden", "tile_radius_frac", "tile_gap_frac", "tile_inset", "accent"]:
		assert_eq(act[k], tgt[k], "p=1.0：%s 必须精确等于目标色板值" % k)


func test_bool_and_string_keys_narrow_immediately() -> void:
	## 布尔/字符串（glass/bg_gradient/flag_style…）没有渐变语义：目标里有 → 首步吸附；
	## 目标里没有（棱镜 → cozy 键集变窄）→ **立即移除**，让 is_glass()/use_bg_gradient()
	## 马上落到 false（背景交叉淡化分支据此启动；残留会让翻转永远等不到）。
	_arm("cozy_prism", "cozy_salt")
	ThemeManager._staged_step(0.02)
	var act: Dictionary = ThemeManager._active
	assert_false(act.has("glass"), "p=0.02：目标无 glass 键 → 应立即从 _active 移除")
	assert_false(ThemeManager.is_glass(), "is_glass() 应立即落 false（否则垫板/背景分支残留）")
	assert_false(ThemeManager.use_bg_gradient(), "use_bg_gradient() 应立即落 false（背景淡化要靠它翻转）")


# ============================ 2. 数字色随配色段渐变 ============================

func test_number_color_lerps_in_color_stage() -> void:
	_arm("cozy_salt", "cozy_prism")
	var from_c: Color = (ThemeManager._nums_from[0] as Color)
	var to_c: Color = (ThemeManager._COZY_NUM["cozy_prism"] as Array)[0]
	ThemeManager._staged_step(0.40)
	assert_eq(ThemeManager.number(1), from_c, "p=0.40：配色段未开始，number(1) 应= 旧主题数字色")
	ThemeManager._staged_step(0.75)
	# 配色段进度 pc = (0.75-0.50)/0.50 = 0.5 ⇒ 精确半程（比「介于两者之间」更强的断言）
	assert_eq(ThemeManager.number(1), from_c.lerp(to_c, 0.5),
		"p=0.75：number(1) 应精确等于半程插值色")
	ThemeManager._staged_step(1.0)
	assert_eq(ThemeManager.number(1), to_c, "p=1.0：number(1) 应精确等于新主题数字色")


# ============================ 3. 波浪系统已移除 ============================

func test_theme_wave_system_is_gone() -> void:
	## 用户要求移除圆形波浪：board_view 源码不得再有波浪引擎的任何标识符。
	var f := FileAccess.open("res://ui/board_view.gd", FileAccess.READ)
	assert_not_null(f, "应能读到 board_view.gd")
	var src := f.get_as_text()
	for banned in ["start_theme_wave", "_tw_col", "_tw_num", "_tw_e_at", "_theme_wave", "TW_NO_POS", "TW_SPEED"]:
		assert_false(src.contains(banned), "board_view.gd 不应再含 %s（波浪已移除）" % banned)
	# 分层过渡的承接点在场：theme_changed 驱动重绘 + 背景交叉淡化
	assert_true(src.contains("ThemeManager.theme_changed.is_connected(queue_redraw)"),
		"board_view 应继续以 theme_changed → queue_redraw 承接换肤")
	assert_true(src.contains("BG_FADE_MS"), "board_view 应有背景交叉淡化（分层过渡的背景层）")


# ============================ 4. 信号与收口 ============================

func test_staged_step_emits_theme_changed_and_final_fires_settled() -> void:
	_arm("cozy_salt", "cozy_prism")
	# ⚠️ GDScript 的 lambda 按值捕获局部变量 ⇒ 计数器必须用 Dictionary（引用语义）。
	var counter := {"changed": 0, "settled": 0}
	var cb := func(): counter["changed"] += 1
	ThemeManager.theme_changed.connect(cb)
	ThemeManager._staged_step(0.10)
	ThemeManager._staged_step(0.50)
	ThemeManager.theme_changed.disconnect(cb)
	assert_gt(int(counter["changed"]), 0, "_staged_step 应广播 theme_changed（棋盘逐帧重绘的驱动源）")
	var sb := func(): counter["settled"] += 1
	ThemeManager.theme_settled.connect(sb)
	ThemeManager._apply_final()
	ThemeManager.theme_settled.disconnect(sb)
	assert_eq(int(counter["settled"]), 1, "_apply_final 应发一次 theme_settled")
	assert_eq(ThemeManager._phase_t, 1.0, "收口后 phase 应 = 1.0（静止态）")
