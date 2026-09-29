# test_board_tile_contract.gd —— CozyStyle 圆角瓦片的**门控契约**（2026-09-29）
#
# 背景：棋盘从「方格 + 网格线」改成「圆角瓦片留缝拼在垫子上」（见 board_view.gd 的
# TILE_GAP_FRAC / TILE_RADIUS_FRAC）。改动集中在三个绘制入口：
#     _draw_tile / _tile_rect / _draw_tile_outline
# 三者必须按**同一判据**门控 —— 只有定义了 board_mat 的 CozyStyle 五套走圆角瓦片，
# dark / light 严格走改造前那一条 draw_rect。
#
# 为什么必须单独立一份测试：
#   · 这个门控**视觉上几乎无法证伪** —— 旧主题走错分支时只是四角变圆、少一圈格线，
#     不并排对比根本看不出来；
#   · 既有 808 条单测一条都不碰绘制路径；
#   · 截图级校验（_pv/diff_legacy_boards.py）能发现「变了」，但分不清「几何变了」还是
#     「位置挪了 1px」—— 事实是那天两处**全局**改动（棋盘字体、图标按钮内边距）让
#     dark/light 的棋盘截图出现 7.6 万像素差异，而瓦片几何其实严格恒等。
# 所以这里把判据钉在**几何恒等**上，而不是钉在截图像素上。
#
# ⚠️ 本文件会直接改 autoload ThemeManager 的 mode/_target/_active（绕开 300ms tween，
#    与 test_theme_manager.gd::_set_theme 同一手法）⇒ 必须在 after_all 里原样还原。
extends GutTest

const BV := preload("res://ui/board_view.gd")
const SRC := "res://ui/board_view.gd"

## 探针矩形：故意取非整数坐标 + 正方形边长。方角路径原样返回、圆角路径内缩，
## 两者不可能碰巧相等，所以「相等」本身就是有约束力的断言。
const PROBE := Rect2(374.5, 70.25, 107.0, 107.0)

## CozyStyle 家族应为 5 套（dusk / haze / sage / salt / terracotta）。
## 写成常量是为了「新接主题忘了配 board_mat」也能被抓住。
const COZY_WITH_MAT := 5

var _saved: Dictionary = {}


func before_all() -> void:
	# 备份 autoload 的主题三件套，结束时还回去（否则会污染后续文件的取色断言）
	_saved = {
		"mode": ThemeManager.mode,
		"target": ThemeManager._target,
		"active": ThemeManager._active,
	}


func after_all() -> void:
	if not _saved.is_empty():
		ThemeManager.mode = _saved["mode"]
		ThemeManager._target = _saved["target"]
		ThemeManager._active = _saved["active"]


# ============================ 工具 ============================

## 同步切主题（绕开 300ms tween）。
func _use(m: String) -> void:
	ThemeManager.mode = m
	ThemeManager._target = ThemeManager._palette_for(m)
	ThemeManager._active = ThemeManager._target.duplicate()


## 全部「具体主题」id（"system" 只是"取默认"，不是一个色板）。
func _theme_ids() -> Array:
	return ThemeManager.THEME_IDS.filter(func(x): return str(x) != "system")


## 挂一个 board_view 实例在树上。**不需要开局**：本文件只碰纯几何/取色函数，
## 与 test_cell_texture.gd 同一做法（那边同样不 start_level）。
func _mount():
	var view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(view)
	return view


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


## 抠出一个顶层函数的源码（GDScript 顶层 func 一律从第 0 列开始）。
## 名字带括号匹配，避免 _draw_tile 误命中 _draw_tile_outline。
func _func_body(src: String, name: String) -> String:
	var lines := src.split("\n")
	var head := "func " + name + "("
	var out: Array[String] = []
	var started := false
	for ln: String in lines:
		var s: String = ln
		if not started:
			if s.begins_with(head):
				started = true
				out.append(s)
			continue
		if s.begins_with("func ") or s.begins_with("const ") or s.begins_with("var "):
			break
		out.append(s)
	return "\n".join(out)


# ============================ 1. 门控判据 ============================

func test_gate_is_exactly_board_mat_alpha() -> void:
	## 判据的唯一性：_cozy_tiles() 必须**逐主题**等于 board_mat().a > 0。
	## 两边各写一份判据就会漂移 —— 例如某天给新主题配了垫子却忘了走瓦片
	## （棋盘变成"垫子上盖着一层方格"，格线压在瓦片外沿），或者反过来
	## （旧主题突然四角变圆）。
	var view = _mount()
	await wait_process_frames(1)
	var with_mat := 0
	var listed: Array[String] = []
	for m: String in _theme_ids():
		_use(m)
		var a: float = ThemeManager.board_mat().a
		var got: bool = view._cozy_tiles()
		# 断言里把 a 打出来，红灯时能直接看出是哪套主题的垫子值不对
		assert_eq(got, a > 0.0,
			"%s：_cozy_tiles()=%s，但 board_mat().a=%.3f（两者必须同步）" % [m, str(got), a])
		if a > 0.0:
			with_mat += 1
			listed.append(m)
	assert_eq(with_mat, COZY_WITH_MAT,
		"应恰有 %d 套主题带 board_mat（实得 %d：%s）"
		% [COZY_WITH_MAT, with_mat, ", ".join(listed)])


# ============================ 2. 零回归（核心）============================

func test_legacy_themes_tile_rect_is_identity() -> void:
	## **本次改动的零回归核心断言。** dark / light 下 _tile_rect 必须是恒等函数 ——
	## 原样返回传入的矩形。这一条一红，就说明两套沿用了很久的主题被默默改了形状，
	## 那不是"观感微调"，是所有既有截图与手工验收标准同时失效。
	##
	## 描边同理：_draw_tile_outline 的旧主题分支走 `rect.grow(-inset)`，
	## 而 Cozy 分支走 `_tile_rect(rect).grow(-inset)` —— 只要 _tile_rect 恒等，
	## 两条分支的 rect 就逐像素一致（同一个 draw_rect 调用）。
	var view = _mount()
	await wait_process_frames(1)
	for m: String in ["dark", "light"]:
		_use(m)
		assert_false(view._cozy_tiles(), "%s 不应走圆角瓦片（board_mat 应全透明）" % m)
		var got: Rect2 = view._tile_rect(PROBE)
		assert_eq(got, PROBE, "%s：_tile_rect 必须原样返回（实得 %s）" % [m, str(got)])


func test_legacy_themes_always_have_a_full_transparent_mat() -> void:
	## 门控的**底座**：dark/light 的 board_mat 必须是**全透明**，不能是"alpha 很小但不为 0"。
	## 判据是 `> 0.0`，所以 0.001 也会打开圆角瓦片 —— 这条把"接近 0 就算没垫子"的
	## 侥幸写法挡掉。
	var view = _mount()
	await wait_process_frames(1)
	for m: String in ["dark", "light"]:
		_use(m)
		var mat: Color = ThemeManager.board_mat()
		assert_eq(mat.a, 0.0, "%s：board_mat 的 alpha 必须精确为 0（实得 %.4f）" % [m, mat.a])


# ============================ 3. CozyStyle 侧必须真的生效 ============================

func test_cozy_themes_shrink_the_tile_by_the_declared_gap() -> void:
	## 反向断言：CozyStyle 五套必须**真的**内缩，且**相邻两格之间的空隙**
	## 恰好等于 `格宽 × TILE_GAP_FRAC`。
	##
	## 少了这一半，把门控写成"永远返回原矩形"也能让上面两条全绿 —— 那样棋盘就退回了
	## 方格 + 网格线，而测试却一片绿。
	##
	## ⚠️ 2026-09-29 二次修订：这里的判据从「单侧内缩 == 格宽 × TILE_GAP_FRAC」
	## 改成了「**两格之间**的空隙 == 格宽 × TILE_GAP_FRAC」。
	## 原因：`Rect2.grow()` 是**四边同时**缩，原来的写法把标称值当成了单侧内缩，
	## 于是实际缝宽是标称值的两倍 —— 而原断言与代码犯了同一个错，所以两边一起绿。
	## 钉住"看得见的那个量"（相邻两格之间的空隙），才能挡住这类系数级错误。
	var view = _mount()
	await wait_process_frames(1)
	var gap_frac: float = BV.TILE_GAP_FRAC
	assert_gt(gap_frac, 0.0, "TILE_GAP_FRAC 应为正数")
	assert_lt(gap_frac, 0.5, "缝宽超过半格就不成瓦片了")
	var checked := 0
	for m: String in _theme_ids():
		_use(m)
		if not view._cozy_tiles():
			continue
		checked += 1
		var inset := maxf(0.5, PROBE.size.x * gap_frac * 0.5)
		var want := PROBE.grow(-inset)
		var got: Rect2 = view._tile_rect(PROBE)
		assert_almost_eq(got.position.x, want.position.x, 1e-4, "%s：瓦片左边界" % m)
		assert_almost_eq(got.position.y, want.position.y, 1e-4, "%s：瓦片上边界" % m)
		assert_almost_eq(got.size.x, want.size.x, 1e-4, "%s：瓦片宽度" % m)
		assert_almost_eq(got.size.y, want.size.y, 1e-4, "%s：瓦片高度" % m)
		# 四边等量内缩 ⇒ 瓦片与格子同心（不然缝会偏到一侧，看起来像格子画歪了）
		assert_almost_eq(got.get_center().x, PROBE.get_center().x, 1e-4,
			"%s：瓦片必须与格子同心（x）" % m)
		assert_almost_eq(got.get_center().y, PROBE.get_center().y, 1e-4,
			"%s：瓦片必须与格子同心（y）" % m)
		# ★ 核心：右邻格（中心相距一个格宽）与本格之间的可见空隙
		var nb := Rect2(PROBE.position + Vector2(PROBE.size.x, 0.0), PROBE.size)
		var visible_gap: float = view._tile_rect(nb).position.x - got.end.x
		assert_almost_eq(visible_gap, PROBE.size.x * gap_frac, 0.5,
			"%s：相邻两格之间的空隙应 ≈ 格宽 × %.3f = %.2fpx（实得 %.2fpx）"
			% [m, gap_frac, PROBE.size.x * gap_frac, visible_gap])
		# 下邻格同理：缝必须四边一致，否则看起来是"只有横向留了缝"
		var nb2 := Rect2(PROBE.position + Vector2(0.0, PROBE.size.y), PROBE.size)
		var gap_v: float = view._tile_rect(nb2).position.y - got.end.y
		assert_almost_eq(gap_v, visible_gap, 0.01,
			"%s：纵向缝(%.2f)必须等于横向缝(%.2f)" % [m, gap_v, visible_gap])
	assert_eq(checked, COZY_WITH_MAT, "应有 %d 套主题走到圆角瓦片（实得 %d）"
		% [COZY_WITH_MAT, checked])


func test_tile_corner_radius_follows_the_declared_fraction() -> void:
	## 圆角半径 = clamp(round(**格边长** × TILE_RADIUS_FRAC), 2, 40)。
	## 上限 40 是防"某个超大视口下圆角吃掉整块瓦片"；下限 2 是防小格子上圆角退化成直角。
	##
	## 按**格边长**而不是内缩后的瓦片边长取 —— 因为 TILE_RADIUS_FRAC 的定义
	## （对齐 CozySudoku 官方截图的实测口径）就是「半径 / 格边长」。
	var view = _mount()
	await wait_process_frames(1)
	var frac: float = BV.TILE_RADIUS_FRAC
	assert_gt(frac, 0.0, "TILE_RADIUS_FRAC 应为正数")
	assert_lt(frac, 0.2,
		"圆角超过格边长的 20%% 就不是「略微倒角」而是「软糖」了 —— "
		+ "原作官方截图实测 10.6%%（格 47px / 半径 5px），当前 %.3f" % frac)
	for m: String in _theme_ids():
		_use(m)
		if not view._cozy_tiles():
			continue
		var raw := maxf(2.0, PROBE.size.x * frac)
		var sb: StyleBoxFlat = view._tile_stylebox(raw)
		var want := clampi(int(roundf(raw)), 2, 40)
		assert_eq(sb.corner_radius_top_left, want, "%s：圆角半径（左上）" % m)
		assert_eq(sb.corner_radius_top_right, want, "%s：圆角半径（右上）" % m)
		assert_eq(sb.corner_radius_bottom_left, want, "%s：圆角半径（左下）" % m)
		assert_eq(sb.corner_radius_bottom_right, want, "%s：圆角半径（右下）" % m)
		# 四角必须一致：任一角不同就是"某边没设到"的典型症状
		assert_true(sb.anti_aliasing, "%s：圆角必须开抗锯齿（否则看出多边形）" % m)



# ============================ 4. 结构性护栏 ============================

func test_all_three_entry_points_carry_the_guard_in_source() -> void:
	## 三个入口必须**各自**带门控。上面所有几何断言只查 _tile_rect —— 如果有人给
	## 描边或填充加个新分支却忘了判主题，几何断言照样全绿，而旧主题已经变样了。
	## 所以这里直接读源码确认门控在场（同 test_code_hygiene.gd 的口径）。
	var src := _read(SRC)
	assert_ne(src, "", "应能读到 %s" % SRC)
	for fn: String in ["_draw_tile", "_tile_rect", "_draw_tile_outline"]:
		var body := _func_body(src, fn)
		assert_ne(body, "", "找不到函数 %s（改名了？本测试要同步改）" % fn)
		assert_true(body.contains("not _cozy_tiles()"),
			"%s 缺少 `not _cozy_tiles()` 门控 ⇒ 旧主题会被卷进圆角瓦片路径" % fn)


# ============================ 5. 那两处「全局」改动（同样作用在旧主题上）============================

func test_board_font_is_the_equal_width_digit_face() -> void:
	## 棋盘数字是 draw_string 画的，**不继承**主题样式 —— 必须显式取字体。
	## 改动前用的是 ThemeDB.fallback_font（引擎内置回退字体），笔画与界面明显两个风格。
	##
	## 2026-09-29 二次修订：从「主题链的 Label 字体（文源圆体）」进一步改成
	## **等宽数字字体**（源柔ゴシック等宽 Heavy，即原作棋盘数字实际用的那一款）。
	##
	## 判据刻意不写成"等于某个资源路径"，而是**它真的等宽** ——
	## 因为比例字体下 `get_string_size("1")=20.5px` 而 `"8"=37.0px`（字号 56 实测，差 45%），
	## 后果是计时器随秒数抖动、格内数字光学中心不一致。这条断言直接钉住这个后果，
	## 将来换成别的等宽字体照样通过。
	var view = _mount()
	await wait_process_frames(1)
	var f: Font = view._board_font()
	assert_not_null(f, "_board_font 不得为 null（否则画不出字）")
	# 无 font override 时，必须命中 UiFonts.digit()
	assert_eq(f, UiFonts.digit(), "无 override 时棋盘字体应走 UiFonts.digit()")
	var w1: float = f.get_string_size("1", HORIZONTAL_ALIGNMENT_LEFT, -1, 56).x
	var w8: float = f.get_string_size("8", HORIZONTAL_ALIGNMENT_LEFT, -1, 56).x
	assert_almost_eq(w1, w8, 0.6,
		"棋盘数字必须等宽：'1'=%.1fpx 而 '8'=%.1fpx（差 %.1fpx = %.0f%%）"
		% [w1, w8, absf(w8 - w1), 100.0 * absf(w8 - w1) / maxf(0.01, w8)])
	# 中文仍要画得出来（回退链在场），否则笔记里的字会变豆腐块
	var wcjk: float = f.get_string_size("剩余雷数", HORIZONTAL_ALIGNMENT_LEFT, -1, 56).x
	assert_gt(wcjk, 56.0 * 3.0, "中文应经由回退链渲染（4 个字至少 3 个字宽）")
	assert_not_null(ThemeDB.fallback_font, "引擎回退字体应恒存在（仅作为最后兜底）")



func test_icon_button_content_area_can_actually_fit_a_22px_icon() -> void:
	## 图标按钮的内容区必须容得下图标本身。踩过的坑：套用文字按钮的 16/8 内边距，
	## 40×40 按钮的内容区只剩 8×8，`expand_icon` 于是老老实实把 22px 的齿轮/书本
	## 画成 8px 的小方块 —— 症状"不像 bug、像设计"，肉眼排查了两轮才发现。
	var pad: int = UiTheme.ICON_PAD
	assert_gt(pad, 0, "ICON_PAD 应为正数")
	assert_lt(pad, UiTheme.BTN_PAD_X,
		"图标内边距必须小于文字内边距（相等就是没修，就是那个坑）")
	var area40 := 40 - 2 * pad
	var area48 := 48 - 2 * pad
	assert_gte(area40, 22, "40×40 图标按钮的内容区应 ≥22px（实得 %d）" % area40)
	assert_gte(area48, 30, "48×48 图标按钮的内容区应 ≥30px（实得 %d）" % area48)

	# style_icon_button 必须**真的**把四边内边距换成 ICON_PAD（不能只改左右）
	var btn := Button.new()
	add_child_autofree(btn)
	UiTheme.style_icon_button(btn)
	var sb: StyleBox = btn.get_theme_stylebox("normal")
	assert_not_null(sb, "style_icon_button 应给 normal 态装上 StyleBox")
	assert_eq(int(sb.content_margin_left), pad, "左边距")
	assert_eq(int(sb.content_margin_right), pad, "右边距")
	assert_eq(int(sb.content_margin_top), pad, "上边距")
	assert_eq(int(sb.content_margin_bottom), pad, "下边距")
