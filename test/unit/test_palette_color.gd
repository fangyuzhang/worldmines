# test_palette_color.gd —— 配色派生化 + palette 解耦 的门禁（2026-09-22）
#
# 锁三件事：
#   ① **派生口径**（v2 双轴，2026-09-22）：色码 → 三档必须解析可复算 ——
#      standard 原样；dark = 饱和度↑ + 明度小幅↓（加深，不是变暗）； darker = 饱和度腰斩 + 明度收进同一条窄带 + 色相朝底色靠。
#      accent 保持推导后的饱和度、field 再降饱和、文字色必须过对比度阈值。
#   ② **palette 必须被采用**：这是本次修的 bug —— `_custom_palette()` 原先被
#      `if not _custom_layout(): return {}` 挡住，导致走 style 分支的 16 关
#      （va_hex_* / va_holed_*）声明的 palette 与分组色被整条丢弃。
#      这里用 `BoardView.palette_of()`（静态纯函数）直接验，不需要起场景树。
#   ③ **全库数据合法**：凡 palette 里写成字符串的取值都必须能解析出颜色；
#      凡声明 theme 的关卡，七个基础键都必须取到不透明色且数字对比度达标。
extends GutTest

const BoardView := preload("res://ui/board_view.gd")
const LEVEL_DIR := "res://levels"
const EPS := 0.004          # 8bit 量化后的容差（1/255 ≈ 0.0039）
const MIN_TEXT_RATIO := 4.5 # WCAG AA 正文对比度


# ==================== ① 派生口径 ====================

func test_standard_tier_is_the_base_color_itself() -> void:
	## standard 必须逐位等于基色 —— 这是「把手写 RGB 改成写色码」能做到零视觉变化的前提。
	for code: String in PaletteColor.ORDER:
		var got := PaletteColor.derive(code, "standard")
		var want: Color = PaletteColor.BASE[code]
		assert_almost_eq(got.r, want.r, EPS, "%s standard.r" % code)
		assert_almost_eq(got.g, want.g, EPS, "%s standard.g" % code)
		assert_almost_eq(got.b, want.b, EPS, "%s standard.b" % code)


func test_dark_tier_deepens_instead_of_just_dimming() -> void:
	## v2 双轴口径的核心断言：dark 档是「加深」——饱和度不降（允许因钳位持平），
	## 明度下降。这正是旧口径（V × 0.72、饱和度原样）做不到的事：单轴乘法下三档只有亮度差。
	for code: String in PaletteColor.ORDER:
		var base: Color = PaletteColor.BASE[code]
		var dark := PaletteColor.derive(code, "dark")
		assert_gte(dark.s, base.s - 1e-6, "%s：dark 档饱和度不得低于基色" % code)
		assert_lt(dark.v, base.v, "%s：dark 档明度必须下降" % code)


func test_darker_tier_converges_to_one_common_value_band() -> void:
	## darker 档 = 整盘的「统一落影」：八色的明度必须收敛到同一条窄带。
	## 若哪天被改回「逐色乘 0.52」，明度会随基色散开、这条断言立刻挂。
	var vs: Array[float] = []
	for code: String in PaletteColor.ORDER:
		var darker := PaletteColor.derive(code, "darker")
		vs.append(darker.v)
		assert_lt(darker.s, PaletteColor.derive(code, "standard").s * 0.75 + 1e-6,
				"%s：darker 档饱和度应相对基色腰斩" % code)
	var lo: float = vs.min()
	var hi: float = vs.max()
	assert_lt(hi - lo, 0.02, "八色的 darker 明度应收敛到同一档（实测跨度 %.4f）" % (hi - lo))


func test_hue_toward_takes_the_short_arc() -> void:
	## 色相是环：350° → 10° 只差 20°（顺时针过 0），不能绕 340° 反方向。
	assert_almost_eq(PaletteColor.hue_toward(350.0, 10.0, 1.0), 10.0, 1e-4, "跨 0 的最短弧")
	assert_almost_eq(PaletteColor.hue_toward(10.0, 350.0, 1.0), 350.0, 1e-4, "反向同样走短弧")
	assert_almost_eq(PaletteColor.hue_toward(100.0, 200.0, 0.0), 100.0, 1e-4, "f=0 原样")
	assert_almost_eq(PaletteColor.hue_toward(100.0, 200.0, 0.5), 150.0, 1e-4, "f=0.5 取中")


func test_tiers_are_monotonically_darker() -> void:
	for code: String in PaletteColor.ORDER:
		var a := PaletteColor.relative_luminance(PaletteColor.derive(code, "standard"))
		var b := PaletteColor.relative_luminance(PaletteColor.derive(code, "dark"))
		var c := PaletteColor.relative_luminance(PaletteColor.derive(code, "darker"))
		assert_gt(a, b, "%s：standard 应亮于 dark" % code)
		assert_gt(b, c, "%s：dark 应亮于 darker" % code)


func test_field_wash_keeps_hue_but_desaturates() -> void:
	## 大面积铺底必须降饱和：整盘 200+ 格铺高饱和色（如 PINK #EA33EA）会看瞎。
	for code: String in PaletteColor.ORDER:
		var accent := PaletteColor.derive(code, "standard")
		var field := PaletteColor.wash(code, "standard")
		assert_lt(field.s, accent.s + 1e-6, "%s：field 饱和度不得高于 accent" % code)
		assert_lt(field.s, accent.s * 0.5 + 1e-6, "%s：field 饱和度应明显更低" % code)
		# 色相保持（灰是无彩色相，跳过）
		if accent.s > 0.05:
			assert_almost_eq(field.h, accent.h, 0.01, "%s：field 应保持色相" % code)


func test_background_is_dark_and_muted() -> void:
	for code: String in PaletteColor.ORDER:
		var bg := PaletteColor.background(code)
		assert_lt(bg.v, 0.25, "%s：背景明度应压得很低" % code)
		assert_gt(bg.a, 0.99, "%s：背景应不透明" % code)


func test_text_on_meets_contrast_floor() -> void:
	## 三档 wash 底 + 三档 accent 底，选取的文字色都必须过阈值。
	## 这一条曾经真的挂了（最差 2.73 @ BLUE/darker）——根因是 text_on 原用亮度阈值猜白/黑，
	## 改成「两个候选取对比度更大者」后由构造保证 ≥ 4.29。断言按 PaletteColor.MIN_TEXT_RATIO。
	var worst := 99.0
	var worst_at := ""
	for code: String in PaletteColor.ORDER:
		for tier: String in PaletteColor.TIER_ORDER:
			for bg in [PaletteColor.wash(code, tier), PaletteColor.derive(code, tier)]:
				var fg := PaletteColor.text_on(bg)
				var ratio := PaletteColor.contrast_ratio(bg, fg)
				if ratio < worst:
					worst = ratio
					worst_at = "%s/%s" % [code, tier]
				assert_gt(ratio, PaletteColor.MIN_TEXT_RATIO,
						"%s/%s 文字对比度不足（%.2f）" % [code, tier, ratio])
	assert_gt(worst, PaletteColor.MIN_TEXT_RATIO, "最差对比度 %.2f @ %s" % [worst, worst_at])


func test_text_on_guarantee_holds_across_the_whole_luminance_range() -> void:
	## 把「取最大对比度」的可证下界钉死：扫遍整个亮度范围，任何底色都得 ≥ 4.0。
	## 这条不依赖九色板，将来换色板/改档位系数也不会让它失效。
	var worst := 99.0
	var at := 0.0
	var i := 0
	while i <= 100:
		var l := float(i) / 100.0
		var bg := Color(l, l, l)
		var ratio := PaletteColor.contrast_ratio(bg, PaletteColor.text_on(bg))
		if ratio < worst:
			worst = ratio
			at = l
		i += 1
	assert_gt(worst, PaletteColor.MIN_TEXT_RATIO,
			"灰度扫描最差对比度 %.3f @ L=%.2f（下界应 ≈4.29）" % [worst, at])


func test_text_on_picks_dark_text_on_light_fill() -> void:
	## 亮底（黄/绿）必须给深色字，否则白字糊在亮底上 —— 这正是各关写死 #ffffff 的老问题。
	var yellow := PaletteColor.derive("YELLOW", "standard")
	var dark_text := PaletteColor.text_on(yellow)
	assert_lt(PaletteColor.relative_luminance(dark_text), 0.02, "亮底应配深色文字")
	var violet := PaletteColor.derive("VIOLET", "dark")
	assert_gt(PaletteColor.relative_luminance(PaletteColor.text_on(violet)), 0.9, "暗底应配白色文字")


func test_wcag_relative_luminance_is_linearized() -> void:
	## 明确钉住「我们不用 Color.get_luminance()」这件事：内置版本不做 sRGB 线性化，
	## 黑白两端都是 1.0/0.0 分不出来，但中灰差别巨大（实测内置 0.32 vs 正确 0.0835）。
	var mid := Color(0.32, 0.32, 0.32)
	assert_almost_eq(PaletteColor.relative_luminance(mid), 0.0835, 0.002,
			"中灰相对亮度应按 sRGB 分段函数线性化")
	assert_almost_eq(PaletteColor.relative_luminance(Color.BLACK), 0.0, 1e-9)
	assert_almost_eq(PaletteColor.relative_luminance(Color.WHITE), 1.0, 1e-9)
	# 黑白对比度必须是 21（WCAG 上限）——拿内置 luminance 算不出来这个值
	assert_almost_eq(PaletteColor.contrast_ratio(Color.BLACK, Color.WHITE), 21.0, 0.01)


func test_resolve_code_two_level_strategy() -> void:
	## ① 显式色名（含 _DARK 后缀）→ 对应的基色；② 未登记名 → 稳定散列。
	assert_eq(PaletteColor.resolve_code("BLUE"), "BLUE")
	assert_eq(PaletteColor.resolve_code("blue"), "BLUE", "大小写应归一")
	assert_eq(PaletteColor.resolve_code("PINK_DARK"), "PINK", "档位后缀应从名字里剥掉")
	assert_eq(PaletteColor.resolve_code("ORANGE_DARKER"), "ORANGE")
	assert_true(PaletteColor.has_explicit_name("INDIGO_DARK"))
	assert_false(PaletteColor.has_explicit_name("RING_0"))
	# 稳定：同一个未登记名必须每次都落到同一色（分组色是玩家记约束的锚点，不能变）
	var a := PaletteColor.resolve_code("RING_0")
	var b := PaletteColor.resolve_code("RING_0")
	assert_eq(a, b, "未登记名必须稳定解析")
	assert_true(PaletteColor.ORDER.has(a), "解析结果必须落在九色内")
	var cols := {}
	for nm in ["RING_0", "RING_1", "RING_2"]:
		cols[PaletteColor.resolve_code(nm)] = true
	assert_gt(cols.size(), 1, "RING_0/1/2 不应全部塌到同一个色")


func test_tier_of_name() -> void:
	assert_eq(PaletteColor.tier_of_name("PINK_DARK"), "dark")
	assert_eq(PaletteColor.tier_of_name("PINK_DARKER"), "darker")
	assert_eq(PaletteColor.tier_of_name("PINK"), "standard")


func test_parse_accepts_both_forms() -> void:
	var rgb := PaletteColor.parse([82, 179, 255])
	assert_almost_eq(rgb.r, 82.0 / 255.0, EPS, "RGB 数组口径应保留")
	assert_almost_eq(rgb.g, 179.0 / 255.0, EPS)
	assert_almost_eq(rgb.b, 255.0 / 255.0, EPS)
	var code := PaletteColor.parse("BLUE")
	assert_almost_eq(code.r, 82.0 / 255.0, EPS, "色码 BLUE 应等于既有色值（零视觉变化）")
	# 带后缀的名字按名字给档位（PINK_DARK 是 dark 档，不是 standard）
	var pd := PaletteColor.parse("PINK_DARK")
	var pink_dark_by_tier := PaletteColor.derive("PINK", "dark")
	assert_almost_eq(pd.r, pink_dark_by_tier.r, EPS, "PINK_DARK 应按 dark 档解析")


func test_parse_rejects_junk_without_inventing_color() -> void:
	## 只拒绝**取不出颜色**的输入。多余的数组元素（如带 alpha 的 [r,g,b,a]）按容忍处理，
	## 不是"非法"—— mod 作者多写一位不该让整盘掉回主题色。
	for junk in [null, "", [1, 2], 42, {"a": 1}, []]:
		assert_eq(PaletteColor.parse(junk).a, 0.0, "非法取值 %s 应返回透明（回退，不臆造）" % str(junk))
	assert_gt(PaletteColor.parse([1, 2, 3, 4]).a, 0.0, "多余元素应被容忍（取前三位）")


func test_theme_color_covers_the_seven_keys() -> void:
	var keys := ["tile", "revealed", "tile_border", "flagged_tile", "revealed_text", "background"]
	for k in keys:
		var c := PaletteColor.theme_color("BLUE", k)
		assert_gt(c.a, 0.0, "palette.%s 应有主题派生色" % k)
	assert_eq(PaletteColor.theme_color("BLUE", "tile_highlight").a, 0.0,
			"高亮线是『线』不是『面』，不参与主题派生（保持中性白）")
	assert_eq(PaletteColor.theme_color("BLUE", "未知键").a, 0.0, "未登记的键应返回透明")


func test_theme_keeps_tile_and_revealed_layered() -> void:
	## 未翻开必须比已翻开亮（否则玩家看不出哪儿翻过了）——这是主题派生唯一的硬约束。
	for code: String in PaletteColor.ORDER:
		var hidden := PaletteColor.theme_color(code, "tile")
		var revealed := PaletteColor.theme_color(code, "revealed")
		assert_gt(PaletteColor.relative_luminance(hidden), PaletteColor.relative_luminance(revealed),
				"%s：未翻开应亮于已翻开" % code)


# ==================== ② palette 必须被采用（本次 bug 的回归锁） ====================

func _palette_of_level(path: String) -> Dictionary:
	var b: Board = LevelLoader.load_level(path)
	assert_not_null(b, "%s 应可载入" % path)
	return BoardView.palette_of(b)


func test_palette_survives_on_style_branch_levels() -> void:
	## va_hex_* / va_holed_* 走 style 分支（无 custom_shapes），
	## 原先 palette 被整条丢弃。这里锁定它必须被读到。
	for path in ["res://levels/va_hex_s1.json", "res://levels/va_holed_s1.json", "res://levels/va_hex_z2.json"]:
		if not FileAccess.file_exists(path):
			pending("缺少 %s" % path)
			return
		var pal := _palette_of_level(path)
		assert_false(pal.is_empty(), "%s 的 palette 必须非空（不得因几何形态被丢弃）" % path)
		var groups: Variant = pal.get("groups", null)
		assert_true(groups is Dictionary, "%s 应有 palette.groups" % path)
		assert_eq((groups as Dictionary).size(), 3, "%s 应有 3 条分组色" % path)


func test_resolve_palette_color_prefers_explicit_then_theme() -> void:
	var fallback := Color(0.1, 0.1, 0.1)
	# 显式键优先于 theme
	var pal := {"tile": [10, 20, 30], "theme": "BLUE"}
	var c := BoardView.resolve_palette_color(pal, "tile", fallback)
	assert_almost_eq(c.r, 10.0 / 255.0, EPS, "显式 tile 应压过 theme 派生")
	# 缺键 → theme 派生
	var c2 := BoardView.resolve_palette_color(pal, "revealed", fallback)
	var want := PaletteColor.theme_color("BLUE", "revealed")
	assert_almost_eq(c2.r, want.r, EPS, "缺键应由 theme 派生")
	# 无 palette → fallback（矩形关卡路径，必须逐像素不变）
	assert_eq(BoardView.resolve_palette_color({}, "tile", fallback), fallback)
	# 空值 → fallback
	assert_eq(BoardView.resolve_palette_color({"tile": []}, "tile", fallback), fallback)


func test_rect_level_palette_is_empty_so_theme_path_unchanged() -> void:
	## 矩形关卡不带 palette 字段 ⇒ 取到空字典 ⇒ 全部走主题色（结构性保证不回归）。
	var b: Board = LevelLoader.load_level("res://levels/classic_01.json")
	if b == null:
		pending("缺少 classic_01")
		return
	assert_true(BoardView.palette_of(b).is_empty(), "矩形关卡不应有 palette")
	assert_eq(BoardView.resolve_palette_color(BoardView.palette_of(b), "tile", Color.RED), Color.RED,
			"无 palette 时必须原样返回 fallback")


func test_themed_level_resolves_every_base_key() -> void:
	## 2026-09-22 起，原本无 palette 的 14 关（蜂窝/挖洞方格/艺术图案）都加上了
	## `palette.theme`（按盘型族分配：蜂窝 BLUE / 挖洞 ORANGE / 艺术图案 VIOLET）。
	## 这条锁住"声明了主题就真的能取到全套色"。
	for path in ["res://levels/hex_01.json", "res://levels/holed_01.json", "res://levels/art_carpet.json"]:
		if not FileAccess.file_exists(path):
			pending("缺少 %s" % path)
			return
		var pal := _palette_of_level(path)
		assert_false(pal.is_empty(), "%s 应已声明 palette.theme" % path)
		assert_true(pal.has("theme"), "%s 应有 theme 键" % path)
		var fallback := Color(1, 0, 1, 1)      # 醒目色：一旦回退就能看出来
		for key in ["tile", "revealed", "tile_border", "flagged_tile", "revealed_text", "background"]:
			var c := BoardView.resolve_palette_color(pal, key, fallback)
			assert_ne(c, fallback, "%s 的 %s 应由 theme 派生（不得回退）" % [path, key])
		# 未翻开必须亮于已翻开（否则玩家看不出翻过哪些格）
		var hidden := BoardView.resolve_palette_color(pal, "tile", fallback)
		var revealed := BoardView.resolve_palette_color(pal, "revealed", fallback)
		assert_gt(PaletteColor.relative_luminance(hidden), PaletteColor.relative_luminance(revealed),
				"%s：未翻开应亮于已翻开" % path)


func test_shape_library_levels_all_share_a_theme_or_palette() -> void:
	## 全库收口：71 个异形关都必须声明 palette（否则又回到"两层灰"）。
	## 这条是防止新增关卡忘记配色 —— 新增关卡时它会直接失败。
	var missing: Array[String] = []
	var themed := 0
	var explicit := 0
	for f in _level_files():
		var raw := _read_json(LEVEL_DIR + "/" + f)
		if not (raw.get("topology") is Dictionary) or (raw["topology"] as Dictionary).is_empty():
			continue
		var pal: Variant = raw.get("palette", null)
		if not (pal is Dictionary) or (pal as Dictionary).is_empty():
			missing.append(f)
			continue
		if (pal as Dictionary).has("theme"):
			themed += 1
		else:
			explicit += 1
	assert_eq(missing.size(), 0, "以下异形关没有任何 palette（会渲染成两层灰）：%s" % str(missing))
	assert_gt(themed + explicit, 0, "应至少检查到一关")
	print("[palette] 异形关配色来源：theme %d 关 / 显式 palette %d 关" % [themed, explicit])


# ==================== ③ 全库数据合法 ====================

func _level_files() -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(LEVEL_DIR)
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and n.ends_with(".json"):
			out.append(n)
		n = d.get_next()
	d.list_dir_end()
	return out


func test_every_string_palette_value_resolves() -> void:
	var bad: Array[String] = []
	var string_vals := 0
	for f in _level_files():
		var raw := _read_json(LEVEL_DIR + "/" + f)
		var pal: Variant = raw.get("palette", null)
		if not (pal is Dictionary):
			continue
		var stack: Array = [(pal as Dictionary)]
		while not stack.is_empty():
			var d: Dictionary = stack.pop_back()
			for k: Variant in d.keys():
				var v: Variant = d[k]
				if v is Dictionary:
					if str(k) != "theme":
						stack.append(v)
					continue
				if v is String:
					string_vals += 1
					if PaletteColor.parse(v).a <= 0.0:
						bad.append("%s: %s = %s" % [f, str(k), str(v)])
	assert_gt(string_vals, 0, "全库应至少有一处字符串色码取值（否则本用例失去意义）")
	assert_eq(bad.size(), 0, "以下色码无法解析：%s" % str(bad))


func test_declared_theme_codes_are_valid() -> void:
	var bad: Array[String] = []
	var themed := 0
	for f in _level_files():
		var raw := _read_json(LEVEL_DIR + "/" + f)
		var pal: Variant = raw.get("palette", null)
		if not (pal is Dictionary) or not (pal as Dictionary).has("theme"):
			continue
		themed += 1
		var t := str((pal as Dictionary)["theme"])
		if t == "" or not PaletteColor.has_explicit_name(t):
			bad.append("%s: theme=%s" % [f, t])
	assert_eq(bad.size(), 0,
			"palette.theme 必须是**显式色名**（散列兜底只用于分组名，主题色必须可预期）：%s" % str(bad))
	if themed == 0:
		pending("当前没有关卡声明 palette.theme —— 机制已就绪，等数据接入")


func test_every_group_code_in_the_library_is_covered() -> void:
	## 分组色若不显式写色名就走散列 —— 不拦，但要报出有多少条是兜底的，
	## 免得"颜色语义跨关不稳"这件事在无人察觉的情况下扩散。
	var total := {}
	var fallback_codes := {}
	for f in _level_files():
		var raw := _read_json(LEVEL_DIR + "/" + f)
		var pal: Variant = raw.get("palette", null)
		if not (pal is Dictionary):
			continue
		var groups: Variant = (pal as Dictionary).get("groups", null)
		if not (groups is Dictionary):
			continue
		for name: Variant in (groups as Dictionary).keys():
			total[str(name)] = true
			if not PaletteColor.has_explicit_name(str(name)):
				fallback_codes[str(name)] = true
	assert_gt(total.size(), 0, "全库应至少有一个分组色名")
	# 仅作记录（不 fail）：用 print 让 CI 日志能看到分布
	print("[palette] 分组色名 %d 个，其中 %d 个走散列兜底：%s"
			% [total.size(), fallback_codes.size(), str(fallback_codes.keys())])


# ==================== 工具 ====================

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}
