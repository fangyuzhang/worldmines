@tool
extends McpTestSuite
## 棱镜玻璃主题 · godot-ai 编辑器内真跑门禁（蒸馏版）。
##
## 与 test/unit/test_theme_manager.gd 第 6 节同公式、同门槛：
## WCAG 亮度/对比/alpha 合成/色距四件套内联，压在「合成后的玻璃表面」上判定。
## 注意：编辑器进程里 autoload 不在场景树，也不可用标识符访问，
## 因此一律 load("res://ui/theme_manager.gd") 取 const，活实例用 .new()。

var _tms: GDScript = null


func suite_name() -> String:
	return "prism_theme"


func suite_setup(_ctx: Dictionary) -> void:
	_tms = load("res://ui/theme_manager.gd")
	if _tms == null:
		fail_setup("无法加载 res://ui/theme_manager.gd")


# ---- WCAG 助手（与 test_theme_manager.gd 完全同公式）----

func _lin(u: float) -> float:
	return u / 12.92 if u <= 0.04045 else pow((u + 0.055) / 1.055, 2.4)


func _lum(c: Color) -> float:
	return 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b)


func _contrast(a: Color, b: Color) -> float:
	var hi: float = max(_lum(a), _lum(b))
	var lo: float = min(_lum(a), _lum(b))
	return (hi + 0.05) / (lo + 0.05)


func _blend(fg: Color, bg: Color) -> Color:
	return Color(
		fg.a * fg.r + (1.0 - fg.a) * bg.r,
		fg.a * fg.g + (1.0 - fg.a) * bg.g,
		fg.a * fg.b + (1.0 - fg.a) * bg.b)


func _color_dist(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(2.0 * dr * dr + 4.0 * dg * dg + 3.0 * db * db) * 255.0


func _prism() -> Dictionary:
	return _tms._COZY.get("cozy_prism", {})


## 玻璃表面合成：页面底 → board_mat → cell_*（与引擎渲染叠层顺序一致）。
func _surface(pal: Dictionary, hidden: bool) -> Color:
	var base := Color("#141834")
	var mat := _blend(pal["board_mat"], base)
	if hidden:
		return _blend(pal["cell_hidden"], mat)
	return _blend(pal["cell_revealed"], mat)


# ---- 用例 ----

func test_prism_theme_is_registered_and_resolves():
	## 【2026-09-30】THEME_IDS/THEME_LABELS 是 static var（Mod 注册表）。Godot 的
	## static 跨脚本热重载**保留旧值**——编辑器进程若缓存过坏解析状态，空数组会
	## 被延续（本轮实锤：磁盘正确、headless 全绿、真机可选中，仅编辑器内类句柄
	## 读到空表）。所以编辑器内门禁只锚 **const 表**（_COZY/_COZY_NUM，永不受
	## static 状态影响）；THEME_IDS 的注册契约由 test/unit/test_theme_manager.gd
	## （每次全新进程）守。
	assert_true(_tms._COZY.has("cozy_prism"), "_COZY 应含 cozy_prism（const，注册事实源）")
	assert_ne(str(_tms._COZY.get("cozy_prism", {}).get("bg", "")), "", "prism 色板 bg 应有值")
	var pal: Dictionary = _prism()
	assert_gt(pal.size(), 14, "prism 色板键集应完整（实得 %d 键）" % pal.size())
	assert_eq((_tms._COZY_NUM["cozy_prism"] as Array).size(), 8, "应有 8 个线索数字色")


func test_prism_glass_paired_roles_readable():
	var pal: Dictionary = _prism()
	var hid: Color = _surface(pal, true)
	var rev: Color = _surface(pal, false)
	assert_gt(_contrast(pal["text"], rev), 4.5, "text/已翻玻璃面（线索数字）")
	assert_gt(_contrast(pal["accent_text"], pal["accent"]), 4.5, "accent_text/accent")
	assert_gt(_contrast(pal["text_secondary"], hid), 3.0, "text_secondary/未翻玻璃面（旗杆）")
	assert_gt(_contrast(pal["danger"], hid), 3.0, "danger/未翻（旗面）")
	assert_gt(_contrast(pal["danger"], rev), 3.0, "danger/已翻（引爆格）")
	assert_gt(_contrast(pal["safe"], hid), 3.0, "safe/未翻（提示描边）")
	assert_gt(_contrast(pal["safe"], rev), 3.0, "safe/已翻")
	assert_gt(_contrast(pal["mine_body"], hid), 3.0, "mine_body/未翻（雷）")
	assert_gt(_contrast(pal["mine_body"], rev), 3.0, "mine_body/已翻（雷）")


func test_prism_glass_numbers_readable_and_distinct():
	var pal: Dictionary = _prism()
	var rev: Color = _surface(pal, false)
	var arr: Array = _tms._COZY_NUM["cozy_prism"]
	var worst := 999.0
	for i in range(arr.size()):
		assert_gt(_contrast(arr[i], rev), 4.5, "数字 %d 压已翻玻璃面" % (i + 1))
		for j in range(i + 1, arr.size()):
			worst = minf(worst, _color_dist(arr[i], arr[j]))
	assert_gt(worst, 45.0, "数字两两色距最差 %.1f 应 >45" % worst)


func test_prism_glass_board_mat_is_translucent_panel():
	## 【2026-09-30 对齐网页 token】垫板 = --mat: rgba(255,255,255,.05) 半透**白**
	## （缝里读出淡灰）；面板辨识度靠 1px 白边（--mat-bd）+ 大柔影（高度），不靠压暗。
	## 旧断言「合成后更暗」是错误设计（白玻璃被做成深色板），已随三层构造修正。
	var pal: Dictionary = _prism()
	var mat: Color = pal["board_mat"]
	assert_true(mat.a > 0.02 and mat.a < 0.15, "board_mat 应为极淡半透层（a=%.3f）" % mat.a)
	assert_true(mat.r >= 0.9 and mat.g >= 0.9 and mat.b >= 0.9, "board_mat 应是白色系（淡灰垫板）")
	assert_true(float(pal.get("mat_border_w", 0)) >= 1, "垫板应有 1px 白边（mat_border_w）")
	assert_gt(float(pal.get("mat_shadow_size", 0.0)), 10.0, "垫板应有大柔影（mat_shadow_size）")


func test_prism_pet_family_complete_and_legible():
	var pal: Dictionary = _prism()
	for k in ["fur", "fur_2", "patch", "ink", "eye", "pupil", "nose", "leaf", "leaf_2", "shadow"]:
		assert_has_key(pal, "pet_" + k, "缺 pet_%s 键" % k)
	var bg: Color = pal["bg"]
	var gates := [
		["fur", bg, 2.0], ["ink", pal["pet_fur"], 3.0], ["patch", pal["pet_fur"], 1.4],
		["eye", pal["pet_fur"], 1.9], ["pupil", pal["pet_eye"], 4.5], ["nose", pal["pet_fur"], 1.4],
		["leaf", bg, 1.4], ["leaf_2", pal["pet_leaf"], 1.2],
	]
	for g in gates:
		assert_gt(_contrast(pal["pet_" + str(g[0])], g[1]), float(g[2]),
			"pet_%s 配对对比不足（需 >%.1f）" % [g[0], float(g[2])])


func test_prism_form_dimensions_present():
	var pal: Dictionary = _prism()
	assert_eq(float(pal.get("tile_gap_frac", 0.0)), 0.07, "tile_gap_frac 应为 0.07")
	assert_eq(float(pal.get("tile_radius_frac", 0.0)), 0.28, "tile_radius_frac 应为 0.28")
	assert_eq(bool(pal.get("glass", false)), true, "glass 应为 true")
	assert_eq(str(pal.get("flag_style", "")), "prism", "flag_style 应为 prism")


## 活实例 getter 链端到端：new 一个 ThemeManager、切到 prism，验证渲染入口 getter。
func test_prism_live_getters_resolve():
	var t = track(_tms.new())
	t.mode = "cozy_prism"
	t._target = t._palette_for("cozy_prism")
	t._active = t._target.duplicate()
	assert_gt(t.board_mat().a, 0.02, "board_mat() getter 应给半透垫（a>0 = 圆角瓦片路径开）")
	assert_true(t.is_glass(), "is_glass() 应为 true")
	assert_true(t.mat_border_w() >= 1, "mat_border_w() getter 应有白边宽度")
	assert_gt(t.mat_shadow_size(), 10.0, "mat_shadow_size() getter 应有大柔影档")
	assert_eq(float(t.tile_gap_frac()), 0.07, "tile_gap_frac() getter")
	assert_eq(float(t.tile_radius_frac()), 0.28, "tile_radius_frac() getter")
	assert_eq(t.flag_style(), "prism", "flag_style() getter")
	assert_eq(t.number(1), (_tms._COZY_NUM["cozy_prism"] as Array)[0], "number(1) 应走 prism 数字表")
