# test_theme_manager.gd —— ThemeManager（全工程唯一合法色源）单元测试
#
# 2026-09-26 补：此前零直接测试（审计盲区清单里视觉依赖最重的文件）。
# 除常规行为外，重点用 **WCAG 对比度公式**锁定两个无障碍取色接口：
#   danger_text()（正文 ≥4.5:1）与 board_grid()（格线非文本 ≥3:1）——
#   这类「看起来对但数字不达标」的问题靠肉眼审不出来。
extends GutTest

const TM := preload("res://ui/theme_manager.gd")

# ---- WCAG 相对亮度 / 对比度 ----
func _lin(u: float) -> float:
	return u / 12.92 if u <= 0.04045 else pow((u + 0.055) / 1.055, 2.4)

func _lum(c: Color) -> float:
	return 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b)

func _contrast(a: Color, b: Color) -> float:
	var hi: float = max(_lum(a), _lum(b))
	var lo: float = min(_lum(a), _lum(b))
	return (hi + 0.05) / (lo + 0.05)

## 半透明前景压在不透明底上的实际渲染色（alpha 混合）
func _blend(fg: Color, bg: Color) -> Color:
	return Color(
		fg.a * fg.r + (1.0 - fg.a) * bg.r,
		fg.a * fg.g + (1.0 - fg.a) * bg.g,
		fg.a * fg.b + (1.0 - fg.a) * bg.b)

func _fresh() -> Node:
	var t: Node = TM.new()
	add_child_autofree(t)
	return t

# ---------- 1. 色板结构 ----------

func test_dark_and_light_share_identical_keys():
	var dk: Dictionary = TM._DARK
	var lt: Dictionary = TM._LIGHT
	assert_eq(dk.keys().size(), lt.keys().size(), "两主题色板键数应一致（漂移=某主题缺色）")
	for k in dk.keys():
		assert_has(lt, k, "亮色板缺键: %s" % k)
	var od: Dictionary = TM._OVERLAY_DARK
	var ol: Dictionary = TM._OVERLAY_LIGHT
	assert_eq(od.keys().size(), ol.keys().size(), "遮罩色板键数应一致")
	for k in od.keys():
		assert_has(ol, k, "亮遮罩缺键: %s" % k)

func test_number_palettes_are_8_valid_colors():
	# 注意：不能用 TM.get("_NUM_DARK") —— get() 是实例方法，类上直接调用是编译错误
	for arr_pair in [["dark", TM._NUM_DARK], ["light", TM._NUM_LIGHT]]:
		var arr: Array = arr_pair[1]
		assert_eq(arr.size(), 8, "%s 应为 8 个（线索 1~8）" % arr_pair[0])
		var seen := {}
		for c in arr:
			assert_true(c is Color, "%s 元素应为 Color" % arr_pair[0])
			assert_false(seen.has(c), "%s 出现重复色（相邻数字同色会无法区分）" % arr_pair[0])
			seen[c] = true

# ---------- 2. 取色接口 ----------

func test_palette_for_applies_overlay_and_ignores_unknown_skin_keys():
	var t = _fresh()
	t._skin_colors = {"bg": Color.RED, "not_a_key": Color.GREEN}
	var p: Dictionary = t._palette_for("dark")
	assert_eq(p["bg"], Color.RED, "已知键应被皮肤覆盖")
	assert_false(p.has("not_a_key"), "未知键必须被忽略（防损坏的皮肤包崩掉色源）")
	assert_eq(p["card"], TM._DARK.card, "未覆盖键保持内置")

## 2026-09-29 修正：本用例原名说的是「`_active` 为空时的兜底」，但旧实现里 `_fresh()` 会跑
## `_ready()` 把 `_active` 填满，所以它实际只验证了「默认主题 == 内置深色」。默认主题已随
## CozyStyle 接入改为「海盐」，故把前提**显式写出来** —— 现在它才真的在测兜底常量本身
## （比旧版更严格：`_active` 确实被清空了）。
func test_getters_fall_back_to_dark_when_active_empty():
	var t = _fresh()
	t.mode = "dark"
	t._active = {}
	assert_eq(t.bg(), TM._DARK.bg)
	assert_eq(t.text(), TM._DARK.text)
	assert_eq(t.grid_line(), TM._DARK.grid_line)
	assert_eq(t.mine_body(), TM._OVERLAY_DARK.mine_body)


## 2026-09-29 新增：默认主题必须落在 CozyStyle 家族（"system" 的落点，见 _settings_mode）。
## 这条守住「新装 / 跟随系统 = 看到新美术」，否则一次重构就可能悄悄退回旧深色。
##
## 注意写法：**直接测 _settings_mode() 的映射，而不是读环境** —— 本机 user://settings.cfg
## 里存着玩家上一次运行选的主题，靠"当前 mode 是什么"来断言会变成一条看天吃饭的用例
##（第一次写就是这样挂的：这台机器上存档是 dark）。改设置都只写内存、不落盘。
func test_default_theme_is_cozy_family():
	var t = _fresh()
	var saved: String = SettingsManager.theme_mode
	SettingsManager.theme_mode = "system"
	assert_eq(t._settings_mode(), TM.DEFAULT_COZY, "跟随系统应落到 CozyStyle 默认主题")
	assert_true(TM.COZY_IDS.has(t._settings_mode()), "默认主题必须属于 CozyStyle 家族")
	# 显式选了主题的人不该被"顺手搬迁"
	for m: String in (["dark", "light"] as Array) + TM.COZY_IDS:
		SettingsManager.theme_mode = m
		assert_eq(t._settings_mode(), m, "显式选择的主题 %s 不得被改写" % m)
	# 脏值 / 未知 id → 落回默认（防手改 settings.cfg 造成空色板 / 取色全兜底）
	for bad: String in ["", "nope", "cozy_unknown", "DARK"]:
		SettingsManager.theme_mode = bad
		assert_eq(t._settings_mode(), TM.DEFAULT_COZY, "未知主题 id（%s）应落回默认" % bad)
	SettingsManager.theme_mode = saved

func test_number_out_of_range_falls_back_to_text():
	var t = _fresh()
	t.mode = "dark"
	t._active = t._palette_for("dark")
	assert_eq(t.number(0), t.text(), "0=空白格，不入数字色")
	assert_eq(t.number(9), t.text(), "9 超界，回退文字色")
	assert_eq(t.number(1), TM._NUM_DARK[0])
	assert_eq(t.number(8), TM._NUM_DARK[7])

func test_skin_number_override_takes_precedence():
	var t = _fresh()
	var custom: Array = []
	for i in range(8):
		custom.append(Color(1.0, 0.5, 0.0, 1.0 - i * 0.09))
	t.apply_skin("my_skin", {}, custom, "dark")
	assert_eq(t.skin_id, "my_skin")
	assert_eq(t.number(3), custom[2], "皮肤数字色优先于内置")

func test_clear_skin_restores_builtin_palette():
	var t = _fresh()
	t._skin_colors = {"bg": Color.RED}
	t.apply_skin("my_skin", {"bg": Color.RED}, [], "dark")
	t.clear_skin("light")
	assert_eq(t.skin_id, "", "清除后 skin_id 归空")
	assert_eq(t._target["bg"], TM._LIGHT.bg, "清除皮肤后底版切到指定内置主题")

func test_transition_ends_exactly_on_target_palette():
	var t = _fresh()
	t.mode = "light"
	t._retarget()   # 300ms lerp 过渡
	await wait_seconds(0.5)
	assert_eq(t._active["bg"], TM._LIGHT.bg,
		"过渡终态必须**精确**等于目标色板——lerp 逐步逼近的残留误差会变成永久色偏")

# ---------- 3. WCAG 对比度（无障碍取色接口的硬指标） ----------

func test_danger_text_meets_wcag_aa_on_both_themes():
	var t = _fresh()
	for m in ["dark", "light"]:
		t.mode = m
		t._active = t._palette_for(m)
		var r: float = _contrast(t.danger_text(), t.bg())
		assert_gt(r, 4.5, "%s 模式 danger_text 压 bg = %.2f:1，WCAG AA 正文要求 ≥4.5:1" % [m, r])

func test_board_grid_meets_non_text_contrast_on_both_themes():
	# board_grid 是半透明线，实际渲染是 alpha 混合 → 必须按**混合后的颜色**算对比
	var t = _fresh()
	for m in ["dark", "light"]:
		t.mode = m
		t._active = t._palette_for(m)
		var blended: Color = _blend(t.board_grid(), t.cell_hidden())
		var r: float = _contrast(blended, t.cell_hidden())
		assert_gt(r, 3.0, "%s 模式 board_grid 混合后压 cell_hidden = %.2f:1，非文本要求 ≥3:1" % [m, r])

func test_text_on_bg_meets_wcag_aa_on_both_themes():
	var t = _fresh()
	for m in ["dark", "light"]:
		t.mode = m
		t._active = t._palette_for(m)
		var r: float = _contrast(t.text(), t.bg())
		assert_gt(r, 4.5, "%s 模式 text 压 bg = %.2f:1，正文 ≥4.5:1" % [m, r])


# ---------- 4. CozyStyle 主题家族（2026-09-29 接入） ----------
#
# 上面三条只覆盖 dark/light（它们是改动前就存在的契约，一字未动）。下面这组**遍历全部
# 主题 id** —— 新主题接进来就自动纳入门禁，不必为每套主题再补一遍用例。这也是本次改造
# 最需要的一道护栏：CozyStyle 原色板是**粉彩低对比**体系（多数角色对 GlobalBg 只有
# 1.0~2.7:1），照字面搬会静默地把上面三条断言搞红。

## 全部「具体主题」id（"system" 只是"用默认"，不是一个可取的色板）。
func _theme_ids() -> Array:
	return TM.THEME_IDS.filter(func(x): return str(x) != "system")


## 把实例切到指定主题并**同步**填满 _active（绕过 300ms tween，便于逐色断言）。
func _set_theme(t: Node, m: String) -> void:
	t.mode = m
	t._target = t._palette_for(m)
	t._active = t._target.duplicate()


## 加权 RGB 色距（0~765；人眼对绿最敏感、蓝最钝）。用于「数字色两两可分」这类判断 ——
## `assert_ne` 只拦"完全相同"，差 1 阶的两种色照样能过，而玩家分不出来。
func _color_dist(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(2.0 * dr * dr + 4.0 * dg * dg + 3.0 * db * db) * 255.0


func test_every_theme_passes_all_three_wcag_gates():
	## 一次遍历把三条硬指标（正文 AA / 危险文字 AA / 格线非文本 AA）+ 配对可读性
	## 全部跑一遍。任何一套主题、任何一个角色掉出门槛都会在这里指出具体主题与比值。
	var t = _fresh()
	for m in _theme_ids():
		_set_theme(t, m)
		var r1: float = _contrast(t.text(), t.bg())
		assert_gt(r1, 4.5, "%s：text/bg = %.2f:1（需 >4.5）" % [m, r1])
		var r2: float = _contrast(t.danger_text(), t.bg())
		assert_gt(r2, 4.5, "%s：danger_text/bg = %.2f:1（需 >4.5）" % [m, r2])
		# 棱镜玻璃不画 board_grid 线（其 board_grid 全透明 ⇒ 混合后与 cell_hidden 同色），
		# 瓦片区隔靠「缝隙 + tile_border + 半透玻璃垫」，由第 6 节的独立护栏验证。
		# 格线 AA 门禁只对真的画格线的主题有意义。
		if not t.is_glass():
			var r3: float = _contrast(_blend(t.board_grid(), t.cell_hidden()), t.cell_hidden())
			assert_gt(r3, 3.0, "%s：board_grid 混合后压 cell_hidden = %.2f:1（需 >3）" % [m, r3])


func test_cozy_paired_roles_are_readable():
	## 「配对色」护栏（CozyStyle 本身就是配对色体系，本次接入把纪律补齐）：
	##   · text 压在 cell_revealed 上 —— 线索数字就画在那儿，糊了整盘就不可读；
	##   · accent_text 压在 accent 上 —— 强调色当底时的字色；
	##   · text_secondary 压在 cell_hidden 上 —— 旗杆（2px 竖条）画在未翻开格上；
	##   · danger / safe / mine_body 压在两种格底上 —— 旗面、雷体、提示描边都是图形，门槛 3:1。
	##
	## **只覆盖 CozyStyle 家族**：旧 dark/light 在同样几条上有本次改造前就存在的缺陷
	##（实测 dark accent_text/accent=1.60、danger/cell_hidden=2.41；light 2.75/2.43），
	## 而它们的 hex 被 test_theme_settings.gd 逐字钉着、不能顺手改（见改造报告「已知缺陷」）。
	## 把它们拉进本用例会让一次**纯追加**的改造看起来像引入了回归。
	var t = _fresh()
	for m in TM.COZY_IDS:
		_set_theme(t, m)
		var rev: Color = t.cell_revealed()
		var hid: Color = t.cell_hidden()
		assert_gt(_contrast(t.text(), rev), 4.5, "%s：text/cell_revealed（线索数字）不足" % m)
		assert_gt(_contrast(t.accent_text(), t.accent()), 4.5, "%s：accent_text/accent 不足" % m)
		assert_gt(_contrast(t.text_secondary(), hid), 3.0, "%s：text_secondary/cell_hidden（旗杆）不足" % m)
		assert_gt(_contrast(t.danger(), hid), 3.0, "%s：danger/cell_hidden（旗面）不足" % m)
		assert_gt(_contrast(t.danger(), rev), 3.0, "%s：danger/cell_revealed（引爆格）不足" % m)
		assert_gt(_contrast(t.safe(), hid), 3.0, "%s：safe/cell_hidden（提示描边）不足" % m)
		assert_gt(_contrast(t.mine_body(), hid), 3.0, "%s：mine_body/cell_hidden（未翻开的雷）不足" % m)
		assert_gt(_contrast(t.mine_body(), rev), 3.0, "%s：mine_body/cell_revealed（已翻开的雷）不足" % m)


func test_legacy_pair_ratios_are_recorded():
	## 纯记录用例（不判定）：把旧 dark/light 的配对可读性实测值打进 GUT 日志，
	## 供改造报告逐条披露 —— 这几处是**本次改造前就存在**的，不是 CozyStyle 带来的。
	## 用 print 而不是 assert：既有缺陷不该在本次改造里变成红灯，但也不该没人知道。
	var t = _fresh()
	for m in ["dark", "light"]:
		_set_theme(t, m)
		print("[legacy-pairs] %s accent_text/accent=%.2f  danger/cell_hidden=%.2f  danger/cell_revealed=%.2f  text_secondary/cell_hidden=%.2f  mine_body/cell_hidden=%.2f" % [
			m,
			_contrast(t.accent_text(), t.accent()),
			_contrast(t.danger(), t.cell_hidden()),
			_contrast(t.danger(), t.cell_revealed()),
			_contrast(t.text_secondary(), t.cell_hidden()),
			_contrast(t.mine_body(), t.cell_hidden())])
	assert_true(true, "纯记录用例")


func test_cozy_palettes_share_identical_keys():
	## 与 test_dark_and_light_share_identical_keys 同口径：五套 CozyStyle 主题的键集必须一致。
	## 漂移 = 某套主题缺色 → 那个主题下会静默回落到 getter 的兜底色（深色），最难查的一类脏。
	var ref: Array = []
	var first := true
	for m in TM.COZY_IDS:
		var keys: Array = (TM._COZY[m] as Dictionary).keys()
		keys.sort()
		if first:
			ref = keys
			first = false
		assert_eq(keys, ref, "%s 的色板键集与首位主题不一致（缺/多键会导致静默回落）" % m)
	assert_gt(ref.size(), 14, "CozyStyle 色板应含 10 主键 + 4 遮罩键 + 3 配对键（>14）")


func test_cozy_number_palettes_are_8_distinct_readable_colors():
	## 8 个线索数字：数量、类型、两两可分（色距）、以及压在 cell_revealed 上的可读性。
	## 色距门槛 45 是本次实测下界（五套主题实测 54.4~61.4）留出的余量。
	var t = _fresh()
	for m in TM.COZY_IDS:
		var arr: Array = TM._COZY_NUM[m]
		assert_eq(arr.size(), 8, "%s 应有 8 个线索数字色" % m)
		for i in range(8):
			assert_true(arr[i] is Color, "%s 第 %d 个应为 Color" % [m, i + 1])
		var worst := 999.0
		var worst_pair := ""
		for i in range(8):
			for j in range(i + 1, 8):
				var d: float = _color_dist(arr[i], arr[j])
				if d < worst:
					worst = d
					worst_pair = "%d-%d" % [i + 1, j + 1]
		assert_gt(worst, 45.0, "%s 数字色距过近（最差 %s = %.1f）——玩家分不出这两个数字" % [m, worst_pair, worst])
		# 数字画在已翻开格上
		_set_theme(t, m)
		for i in range(8):
			var r: float = _contrast(arr[i], t.cell_revealed())
			assert_gt(r, 4.5, "%s 数字 %d 压 cell_revealed 只有 %.2f:1" % [m, i + 1, r])


func test_cozy_theme_ids_and_labels_are_consistent():
	## 显示名表必须覆盖每个 id —— 设置页下拉是**按表渲染**的，漏一个就会显示成裸 id。
	for m in TM.THEME_IDS:
		assert_true(TM.THEME_LABELS.has(m), "THEME_LABELS 缺 %s 的显示名" % m)
		assert_ne(str(TM.THEME_LABELS[m]), "", "%s 的显示名不得为空" % m)
	for m in TM.COZY_IDS:
		assert_true(TM.THEME_IDS.has(m), "COZY_IDS 的 %s 必须也在 THEME_IDS 里（否则下拉里选不到）" % m)
	assert_true(TM.THEME_IDS.has(TM.DEFAULT_COZY), "默认主题必须在 THEME_IDS 里")


# ---------- 5. 全局接线（2026-09-29 补：这两个洞都是「截图验收」抓出来的） ----------

func test_all_palette_color_components_are_in_unit_range():
	## 【事故护栏】生成脚本曾把 rgba(40,49,64,0.62) 渲染成 `Color(40, 49, 64, 0.62)`，
	## 而 Godot 的 Color(float,...) 分量是 **0~1** —— 40/49/64 成了 HDR 值，写入画布时被裁到
	## 1.0 ⇒ 棋盘格线实际画出来是**纯白**（实测 to_html 得到 ffffff9e）。
	##
	## 最阴的地方是三条 WCAG 断言**照样全绿**：测试里的亮度公式直接吃 40.0 得到巨大亮度，
	## 对比度爆表，反而轻松越过 3:1 门槛。也就是说「渲染对不对」与「断言过不过」在这类
	## 数值错误上完全脱钩 —— 只能单独钉一条量纲检查。
	for m in _theme_ids():
		for k in (TM._COZY.get(m, {}) as Dictionary).keys():
			var v = TM._COZY[m][k]
			# 棱镜玻璃的色板混入了「形态维度」键（tile_gap_frac / glass / flag_style …
			# 是 float / bool / String，不是颜色），量纲检查只对真正的 Color 做。
			if not (v is Color):
				continue
			_assert_unit(v, "CozyStyle/%s/%s" % [m, k])
	for m in TM.COZY_IDS:
		var arr: Array = TM._COZY_NUM[m]
		for i in range(arr.size()):
			_assert_unit(arr[i], "CozyStyle数字/%s[%d]" % [m, i + 1])
	for k in TM._DARK.keys():
		_assert_unit(TM._DARK[k], "dark/%s" % k)
	for k in TM._LIGHT.keys():
		_assert_unit(TM._LIGHT[k], "light/%s" % k)
	for k in TM._OVERLAY_DARK.keys():
		_assert_unit(TM._OVERLAY_DARK[k], "overlay_dark/%s" % k)
	for k in TM._OVERLAY_LIGHT.keys():
		_assert_unit(TM._OVERLAY_LIGHT[k], "overlay_light/%s" % k)
	for i in range(TM._NUM_DARK.size()):
		_assert_unit(TM._NUM_DARK[i], "num_dark[%d]" % i)
	for i in range(TM._NUM_LIGHT.size()):
		_assert_unit(TM._NUM_LIGHT[i], "num_light[%d]" % i)


func _assert_unit(c: Color, label: String) -> void:
	## 分量必须落在 0~1。写不出「0~1」用 assert_between 的组合，就逐分量判定。
	for pair in [["r", c.r], ["g", c.g], ["b", c.b], ["a", c.a]]:
		var name: String = pair[0]
		var v: float = pair[1]
		assert_true(v >= 0.0 and v <= 1.0,
			"%s 的 %s = %s 超出 0~1（Godot 的 Color(float...) 要求 0~1；写成 0~255 会在渲染时被裁成纯白，而对比度断言反而会因亮度爆表而误判通过）"
			% [label, name, str(v)])


func test_board_mat_separates_the_board_from_the_page():
	## 缘起：cell_revealed 取的就是 GlobalBg，而 board_view 没有棋盘背景节点 ⇒
	## 已翻开的格与页面底色**完全同色**，棋盘边界只剩 1px 格线。垫子（board_mat）就是补这一层。
	## 两条一起钉住：
	##   · CozyStyle 家族：垫子必须不透明，且对 cell_revealed ≥3:1（非文本相邻色口径）；
	##   · 旧 dark/light：必须**全透明** —— 返回透明 = _draw_board_mat 一个矩形都不画，
	##     旧主题逐像素不变。这条是「纯追加」承诺的可执行版本。
	var t = _fresh()
	for m in TM.COZY_IDS:
		_set_theme(t, m)
		var mat: Color = t.board_mat()
		assert_gt(mat.a, 0.99, "%s：CozyStyle 主题的棋盘垫子必须不透明" % m)
		var r: float = _contrast(mat, t.cell_revealed())
		assert_gt(r, 3.0, "%s：board_mat 压 cell_revealed 只有 %.2f:1（需 >3）" % [m, r])
	for m in ["dark", "light"]:
		_set_theme(t, m)
		assert_eq(t.board_mat().a, 0.0, "%s：旧主题不得画棋盘垫子（否则就是视觉回归）" % m)


# ============================ 6. 棱镜玻璃（半透明玻璃体系，独立护栏）============================
#
# cozy_prism 是**半透明玻璃**主题：cell_hidden / cell_revealed / board_mat 三个角色都是 alpha<1 的
# 玻璃层，且配了 bg_gradient + 烘焙渐变 PNG。它**故意**不满足 CozyStyle 的三条不透明契约
# （键集一致 / 不透明配对可读性 / board_mat 不透明），所以被排除在 COZY_IDS 之外、在此单独守。
#
# 关键：引擎里这些玻璃层是**逐层叠在烘焙渐变上**画的（_draw_prism_background → _draw_board_mat →
# _draw_tile）。WCAG 对比度判定必须把同一合成顺序复现出来，否则测的是「原料色」而非「玩家看到的色」。

## 把棱镜玻璃的层合成成「玩家看到的不透明表面」（与引擎 draw 顺序一致）。
## _blend(fg, bg) = 半透明 fg 压在不透明 bg 上的合成 RGB；贝壳链条：渐变底(近似取最深色) → 垫子 → 格底。
func _prism_surface(t, hidden: bool) -> Color:
	var base := Color("#141834")                       # 渐变 PNG 的最深色（保守下限）
	var mat := _blend(t.board_mat(), base)            # 玻璃垫压在底上
	if hidden:
		return _blend(t.cell_hidden(), mat)           # 乳白毛玻璃未翻格
	return _blend(t.cell_revealed(), mat)             # 清透压暗已翻格


func test_prism_glass_paired_roles_are_readable():
	## 半透明配对可读性：先合成表面，再上 WCAG。门槛与 CozyStyle 段一致（正文≥4.5 / 图形≥3），
	## 差别只是「底色」是合成后的玻璃表面，不是某个不透明角色色。
	var t = _fresh()
	_set_theme(t, "cozy_prism")
	var hid := _prism_surface(t, true)
	var rev := _prism_surface(t, false)
	assert_gt(_contrast(t.text(), rev), 4.5, "prism：text/cell_revealed 不足")
	assert_gt(_contrast(t.accent_text(), t.accent()), 4.5, "prism：accent_text/accent 不足")
	assert_gt(_contrast(t.text_secondary(), hid), 3.0, "prism：text_secondary/cell_hidden（旗杆）不足")
	assert_gt(_contrast(t.danger(), hid), 3.0, "prism：danger/cell_hidden（旗面）不足")
	assert_gt(_contrast(t.danger(), rev), 3.0, "prism：danger/cell_revealed（引爆格）不足")
	assert_gt(_contrast(t.safe(), hid), 3.0, "prism：safe/cell_hidden 不足")
	assert_gt(_contrast(t.safe(), rev), 3.0, "prism：safe/cell_revealed 不足")
	assert_gt(_contrast(t.mine_body(), hid), 3.0, "prism：mine_body/cell_hidden（未翻开的雷）不足")
	assert_gt(_contrast(t.mine_body(), rev), 3.0, "prism：mine_body/cell_revealed（已翻开的雷）不足")


func test_prism_glass_number_colors_are_readable_and_distinct():
	## 8 个线索数字：压在「已翻格合成表面」上可读（≥4.5），且两两色距 ≥45（玩家分得清）。
	## 门槛与 CozyStyle 段一致；prism 是明亮的霓虹玻璃色，色距天然比粉彩宽，46.7 是实测下界留的余量。
	var t = _fresh()
	_set_theme(t, "cozy_prism")
	var rev := _prism_surface(t, false)
	var arr: Array = TM._COZY_NUM["cozy_prism"]
	assert_eq(arr.size(), 8, "prism 应有 8 个线索数字色")
	var worst := 999.0
	var worst_pair := ""
	for i in range(8):
		assert_true(arr[i] is Color, "prism 第 %d 个应为 Color" % [i + 1])
		assert_gt(_contrast(arr[i], rev), 4.5,
			"prism 数字 %d 压 cell_revealed 只有 %.2f:1" % [i + 1, _contrast(arr[i], rev)])
		for j in range(i + 1, 8):
			var d: float = _color_dist(arr[i], arr[j])
			if d < worst:
				worst = d
				worst_pair = "%d-%d" % [i + 1, j + 1]
	assert_gt(worst, 45.0, "prism 数字色距过近（最差 %s = %.1f）——玩家分不出这两个数字" % [worst_pair, worst])


func test_prism_glass_board_mat_is_a_translucent_panel():
	## 【2026-09-30 对齐网页 token 修正】棱镜垫板是网页 --mat: rgba(255,255,255,.05)
	## —— **半透明白**，缝里透出「淡灰」；面板的辨识度来自白边（--mat-bd）与大柔影
	## （box-shadow 0 30px 70px -30px rgba(0,0,0,.6) = 悬浮高度），**不是靠压暗**。
	## 旧断言「合成后比底色更暗」是把网页的白玻璃面板做成了深色板的错误设计，
	## 本用例改钉网页原值方向（三层构造：瓦片 → 淡灰垫板 → 透镜底）。
	var t = _fresh()
	_set_theme(t, "cozy_prism")
	var mat: Color = t.board_mat()
	assert_true(mat.a > 0.02 and mat.a < 0.15,
		"prism：board_mat 应是极淡半透层（a=%.3f，应 0.02~0.15）" % mat.a)
	assert_true(mat.r >= 0.9 and mat.g >= 0.9 and mat.b >= 0.9,
		"prism：board_mat 应是白色系（淡灰垫板层），实得 %s" % mat)
	# 三件套之二：白边（网页 --mat-bd: 1px solid rgba(255,255,255,.14)）
	assert_gte(t.mat_border_w(), 1, "prism：垫板必须有 1px 白边")
	assert_gt(t.mat_border().a, 0.05, "prism：垫板白边必须可见（a>0.05）")
	# 三件套之三：大柔影显高度（区别于 cozy 垫板的 shadow_size=10 小阴影）
	assert_gt(t.mat_shadow_size(), 10.0, "prism：垫板影必须是大柔影（size>10）")
	assert_gt(t.mat_shadow_offset().y, 0.0, "prism：投影向下（光源在上 = 高度感）")
	assert_gt(t.mat_shadow_color().a, 0.3, "prism：投影必须足够深才读得出高度")


func test_prism_glass_pet_family_is_complete_and_legible():
	## 棱镜玻璃的伙伴色走玻璃体系，不进 test_companion_pet 的不透明 WCAG 门禁；这里单独守：
	## (a) 10 个 pet_* 键齐全；(b) 8 条配对护栏（与 CozyStyle 同门槛）达标。
	## 玻璃主题的 pet 是画在棋盘玻璃面上的，门禁取的 bg 用主题 bg（#141834），与 CozyStyle 同口径。
	var want: Array = ["fur", "fur_2", "patch", "ink", "eye", "pupil", "nose",
		"leaf", "leaf_2", "shadow"]
	var gates: Array = [
		["fur", "bg", 2.0], ["ink", "fur", 3.0], ["patch", "fur", 1.4],
		["eye", "fur", 1.9], ["pupil", "eye", 4.5], ["nose", "fur", 1.4],
		["leaf", "bg", 1.4], ["leaf_2", "leaf", 1.2],
	]
	var t = _fresh()
	_set_theme(t, "cozy_prism")
	var pal: Dictionary = t._active
	var lack: Array = []
	for k in want:
		if not pal.has("pet_" + k):
			lack.append(k)
	assert_eq(lack, [], "prism 缺 pet_* 键：%s" % str(lack))
	for gi in gates.size():
		var g: Array = gates[gi]
		var a: Color = pal["pet_" + str(g[0])]
		var bcol: Color = (Color("#141834") if str(g[1]) == "bg" else pal["pet_" + str(g[1])])
		var r: float = _contrast(a, bcol)
		assert_gt(r, float(g[2]),
			"prism P%d pet_%s⊥%s = %.3f:1（需 >%.1f）" % [gi + 1, g[0], g[1], r, float(g[2])])


func test_text_on_returns_a_legible_foreground():
	## 缘起：工程里大量选中态/强调态把底色换成 accent 系淡化色，字色却固定写 text()。
	## 深/浅两套主题各自"看着还行"，接五套粉彩后同一个 darkened() 系数在五个色相上给出
	## 完全不同的明度 ⇒ 必有几个糊掉。text_on() 按实测对比度挑前景，这里把它的承诺钉住。
	## 底色取工程中**真实出现过**的几种：accent 本身、accent 三档淡化、safe 淡化、卡片。
	var t = _fresh()
	for m in _theme_ids():
		_set_theme(t, m)
		var bases: Array = [
			t.accent(), t.accent().darkened(0.5), t.accent().darkened(0.78),
			t.safe().darkened(0.55), t.text_secondary().darkened(0.35), t.card(),
		]
		for b in bases:
			var base: Color = b
			var fg: Color = t.text_on(base)
			var r: float = _contrast(fg, base)
			assert_gt(r, 4.5, "%s：text_on(#%s) 只给出 %.2f:1" % [m, base.to_html(false), r])
