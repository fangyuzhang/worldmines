# test_theme_modding.gd —— 【2026-09-30 开放性】Mod/皮肤改装能力的契约测试。
#
# 覆盖三条开放性通道（审计后补齐的扩展点）：
#   ① ThemeManager.register_theme / unregister_theme：Mod 与皮肤包可注册全新主题 id
#     （THEME_IDS/THEME_LABELS 已 const → var；数字表、family 判定、下拉列表全动态感知）。
#   ② 皮肤 palette 白名单覆盖：pet_*（伙伴猫）与形态维度键（tile_* / flag_style 等）
#     允许覆盖到**任意底版**（含 dark/light）——旧规则「只覆盖 base 已有键」把
#     「深底换猫色 / 旧主题上圆角瓦片」全堵死了。
#   ③ pet_c 的皮肤显式键优先于 dark/light 派生（配合派生代际缓存的失效正确性）。
#
# ⚠️ 本文件会改动 ThemeManager 全局状态（注册主题 / apply_skin）。每个用例**当场
# 恢复**（unregister / clear_skin），否则会污染同进程的其它测试
#（test_companion_pet 的 n_themes 精确断言、test_theme_settings 的 hex 逐字断言）。
extends GutTest

const TM_PATH := "res://ui/theme_manager.gd"


func _tm() -> ThemeManager:
	return get_node("/root/ThemeManager") as ThemeManager


## 同步收口：跳过 300ms 过渡 tween，把 _target 直拷进 _active。
## （与 test_theme_manager.gd 的 _set_theme 同一套路；取色 getter 全走 _active。）
func _settle(tm: ThemeManager) -> void:
	tm._active = (tm._target as Dictionary).duplicate()
	tm._phase_t = 1.0   # 【2026-09-30 分层过渡】同步收口，number() 不再读插值中间态


func test_register_theme_adds_selectable_id() -> void:
	var tm := _tm()
	var pal := {
		"bg": "#101418", "card": "#1a2026", "cell_hidden": "#202830",
		"cell_revealed": "#101418", "text": "#e8eef2", "text_secondary": "#9fb0ba",
		"accent": "#4fa3d1", "danger": "#c0392b", "safe": "#2e8b57",
		"board_mat": "#0c1013",
	}
	var r := tm.register_theme("mod_test_neon", pal, [], "霓虹测试")
	assert_true(bool(r.get("ok", false)), "注册应成功: " + str(r.get("reason", "")))
	assert_true(tm.THEME_IDS.has("mod_test_neon"), "THEME_IDS 应含新 id")
	assert_eq(str(tm.THEME_LABELS.get("mod_test_neon", "")), "霓虹测试", "显示名应写入")
	assert_eq(tm.theme_label("mod_test_neon"), "霓虹测试", "theme_label 应返回自定义名")
	# 色板消费：_palette_for 直接返回自定义色板（皮肤覆盖层之后取）
	var p := tm._palette_for("mod_test_neon")
	assert_eq(p.get("bg"), Color("#101418"), "自定义 bg 应可取")
	# 家族判定：自定义主题应走 cozy_family 分支（board_mat 不透明 → 圆角瓦片路径）
	assert_true(tm.is_cozy_family("mod_test_neon"), "自定义主题应属广义 cozy 家族")
	# 收尾（勿污染其它用例的 n_themes 精确断言）
	assert_true(bool(tm.unregister_theme("mod_test_neon").get("ok", false)), "反注册应成功")
	assert_false(tm.THEME_IDS.has("mod_test_neon"), "反注册后 THEME_IDS 不应再含该 id")


func test_register_theme_rejects_bad_input() -> void:
	var tm := _tm()
	assert_false(bool(tm.register_theme("", {}, []).get("ok", true)), "空 id 应拒绝")
	assert_false(bool(tm.register_theme("Bad Id!", {"bg": "#000"}, []).get("ok", true)),
		"非法字符 id 应拒绝")
	assert_false(bool(tm.register_theme("dark", {"bg": "#000"}, []).get("ok", true)),
		"与内置重名应拒绝")
	assert_false(bool(tm.register_theme("mod_test_bad", {"bg": "#000"}, []).get("ok", true)),
		"缺核心键（cell_hidden/text/accent）应拒绝")
	assert_false(bool(tm.unregister_theme("dark").get("ok", true)), "内置主题不可反注册")


func test_register_theme_with_numbers_and_mode_switch() -> void:
	var tm := _tm()
	var pal := {
		"bg": "#0e0e12", "card": "#16161c", "cell_hidden": "#1c1c24",
		"cell_revealed": "#0e0e12", "text": "#f0f0f4", "text_secondary": "#a0a0ac",
		"accent": "#7a5fd0", "danger": "#b03040", "safe": "#30a060",
		"board_mat": "#0e0e12",
	}
	var nums := ["#ff5555", "#ffaa55", "#ffff55", "#55ff55", "#55ffff", "#5555ff", "#ff55ff", "#ffffff"]
	var r := tm.register_theme("mod_test_num", pal, nums, "数字测试")
	assert_true(bool(r.get("ok", false)), "注册（带 8 数字色）应成功")
	assert_eq((tm.numbers_for("mod_test_num") as Array).size(), 8, "numbers_for 应返回 8 色")
	# 切到自定义主题（number()/board_mat() 都随当前 mode 走，必须先切）→ 同步收口
	SettingsManager.set_theme_mode("mod_test_num")
	_settle(tm)
	assert_eq(tm.mode, "mod_test_num", "theme_mode 应接受自定义 id")
	assert_eq(tm.number(1), Color("#ff5555"), "number(1) 应读自定义数字表")
	assert_eq(tm.board_mat(), Color("#0e0e12"), "board_mat 应读自定义色板")
	# 收尾：先切走再反注册（unregister 内部也会兜底回 DEFAULT_COZY）
	SettingsManager.set_theme_mode("cozy_salt")
	assert_true(bool(tm.unregister_theme("mod_test_num").get("ok", false)), "反注册应成功")


func test_skin_palette_can_override_pet_and_form_on_dark_base() -> void:
	var tm := _tm()
	var fur := Color("#ff00ff")
	var inset := Color("#123456")
	# 深色底版 + pet_*/tile_inset 白名单覆盖：旧规则下这两类键会被静默丢弃
	tm.apply_skin("mod_test_pet", {
		"pet_fur": fur, "tile_inset": inset,
	}, [], "dark")
	_settle(tm)
	# pet_c：皮肤显式键应压过 dark 主题的 WCAG 派生（pet_c 实现里 _skin_colors 最先查）
	assert_eq(tm.pet_c("fur"), fur, "dark 底版下皮肤 pet_fur 应生效（不再派生）")
	# 形态维度：tile_inset 在 dark 底版也应可覆盖（board_view 圆角瓦片高光读取它）
	assert_eq(tm.tile_inset(), inset, "dark 底版下皮肤 tile_inset 应生效")
	# 数字色照旧生效
	tm.apply_skin("mod_test_pet", {"pet_fur": fur}, [Color("#111111"), Color("#222222"),
		Color("#333333"), Color("#444444"), Color("#555555"), Color("#666666"),
		Color("#777777"), Color("#888888")], "dark")
	assert_eq(tm.number(1), Color("#111111"), "皮肤数字色应在 dark 底版生效")
	# 收尾：清皮肤并切回默认 cozy（避免污染后续用例的 theme_mode/pet 派生缓存）
	tm.clear_skin("cozy_salt")
	SettingsManager.set_theme_mode("cozy_salt")


func test_pet_c_cache_invalidates_on_skin_change() -> void:
	var tm := _tm()
	tm.clear_skin("cozy_salt")
	_settle(tm)   # 前一个用例的过渡可能还没收口，先同步到 cozy_salt 目标色板
	var base_fur := tm.pet_c("fur")
	var custom := Color("#00ff88")
	tm.apply_skin("mod_test_cache", {"pet_fur": custom}, [], "cozy_salt")
	assert_eq(tm.pet_c("fur"), custom, "换皮肤后 pet_c 应立即反映新毛色（代际缓存失效）")
	tm.clear_skin("cozy_salt")
	_settle(tm)
	# 清皮肤后回到主题自带值（cozy_salt 有 pet_fur 键）
	assert_eq(tm.pet_c("fur"), (tm._palette_for("cozy_salt") as Dictionary).get("pet_fur"),
		"清皮肤后 pet_c 应回到主题自带值")
	# 消除 unused 警告（base_fur 仅用于确保首次调用建立缓存）
	assert_true(base_fur != null, "首次取值应成功")
	SettingsManager.set_theme_mode("cozy_salt")
