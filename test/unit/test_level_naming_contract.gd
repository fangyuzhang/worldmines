# test_level_naming_contract.gd —— 关卡「名字 / 主题 / 纹理」与规则表的一致性契约（2026-09-24）
#
# 背景（交叉验证所得，三个都真实存在过的坑）：
#
#   ① **名字与规则不符（玩家可见）**：`ani_snowflake` 写着「雪花 · 偶偶」，可 global_rules 是 s2。
#      原因是 s6（偶偶）在该形状上求解超时，逐轮换到 s2（见 gen_shape_levels.gd 的约束调整记录），
#      **规则换了、名字没跟着换** —— 于是选关页显示的名字和实际玩的规则不是一回事。
#   ② **变体关的 theme 与 BY_VARIANT 漂移**：`ani_turtle` 是 s2，theme 却是 GREEN（应 BLUE）；
#      `ani_snowflake` 是 s2，theme 是 PINK（应 BLUE）。成因是 SPEC 里的 explicit theme 陈旧，
#      而 explicit 优先级最高 ⇒ 重跑会把错值原样写回。
#   ③ 同理 texture 也可能漂移。
#
# 修法（本测试锁住）：SPEC 里**不要**给变体关写 explicit theme/texture —— 由规则表唯一决定；
# 名字的后缀必须取自 VariantCatalog.display_name（变体 Mod 的 describe 是唯一事实源）。
extends GutTest

const ThemeMarks := preload("res://tools/theme_marks.gd")
const TextureMarks := preload("res://tools/texture_marks.gd")


## 收集「关卡路径 → {vid, name, theme, texture}」。
func _variant_levels() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for path in LevelLoader.list_levels():
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var d: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if not (d is Dictionary):
			continue
		var lv: Dictionary = d
		var gr: Variant = lv.get("global_rules", [])
		if not (gr is Array) or (gr as Array).is_empty():
			continue
		var pal: Variant = lv.get("palette", {})
		var palette: Dictionary = pal if pal is Dictionary else {}
		out.append({
			"path": path,
			"vid": str((gr as Array)[0]),
			"name": str(lv.get("name", "")),
			"theme": str(palette.get("theme", "")),
			"texture": str(palette.get("texture", "")),
		})
	return out


func test_level_name_suffix_matches_variant_display_name() -> void:
	## 数据里的「形状 · 变体名」后缀必须等于 VariantCatalog.display_name(global_rules[0])。
	## 为什么需要：实测「雪花 · 偶偶」实际跑的是 s2 —— 名字换了规则没换（或反之），
	## 玩家在选关页看到的名字与真实玩法不符。display_name 是唯一事实源。
	var bad: Array[String] = []
	var checked := 0
	for info: Dictionary in _variant_levels():
		var vid := str(info["vid"])
		var official := VariantCatalog.display_name(vid)
		if official == vid:
			continue          # 该变体未登记（未来新增 / Mod 未加载）：跳过，不误报
		var nm := str(info["name"])
		if not nm.contains("·"):
			continue          # 名字没带变体后缀：不在本契约管辖内
		checked += 1
		var suffix := nm.get_slice("·", 1).strip_edges()
		# 剥掉有意的「#N」——同形状同变体有多关时用它区分（如「行列凸 #4」），
		# 是关卡编号而非变体名的一部分。
		var hash_i := suffix.find("#")
		if hash_i > 0:
			suffix = suffix.substr(0, hash_i).strip_edges()
		if suffix != official:
			bad.append("%s：名后缀「%s」≠ display_name「%s」" % [
				str(info["path"]).get_file(), suffix, official])
	assert_gt(checked, 0, "应至少检查到一个带变体后缀的关卡")
	assert_eq(bad.size(), 0,
		"以下关卡的名字与变体官方名不一致（规则换了名字没换，或用了旧昵称）：\n%s" % "\n".join(bad))


func test_variant_level_theme_matches_rule_table() -> void:
	## 变体关的 theme 必须等于 ThemeMarks 的变体轴取值。
	## 为什么需要：SPEC 里的 explicit theme 陈旧时会原样写回（explicit 优先级最高），
	## 令「s2 恒为蓝」这类变体色彩语言在库内不成立 —— 玩家失去第二识别通道。
	var bad: Array[String] = []
	var checked := 0
	for info: Dictionary in _variant_levels():
		var vid := str(info["vid"])
		if not ThemeMarks.BY_VARIANT.has(vid):
			continue          # 该变体无主题席位（如未登记的轴）：跳过
		checked += 1
		var want := str(ThemeMarks.BY_VARIANT[vid])
		var got := str(info["theme"])
		if got != want:
			bad.append("%s：var=%s theme=%s（规则表要求 %s）" % [
				str(info["path"]).get_file(), vid, got, want])
	assert_gt(checked, 0, "应至少检查到一个有主题席位的变体关")
	assert_eq(bad.size(), 0,
		"以下变体关的 theme 与规则表漂移（SPEC 里可能残留了陈旧 explicit 值）：\n%s" % "\n".join(bad))


func test_variant_level_texture_matches_rule_table() -> void:
	## 变体关的 texture 必须等于 TextureMarks 的变体轴取值（无席位的变体跳过）。
	var bad: Array[String] = []
	var checked := 0
	for info: Dictionary in _variant_levels():
		var vid := str(info["vid"])
		if not TextureMarks.BY_VARIANT.has(vid):
			continue
		checked += 1
		var want := str(TextureMarks.BY_VARIANT[vid])
		var got := str(info["texture"])
		if got != want:
			bad.append("%s：var=%s texture=%s（规则表要求 %s）" % [
				str(info["path"]).get_file(), vid, got, want])
	assert_gt(checked, 0, "应至少检查到一个有纹理席位的变体关")
	assert_eq(bad.size(), 0,
		"以下变体关的 texture 与规则表漂移：\n%s" % "\n".join(bad))


func test_every_axis_present_in_library_has_both_channels() -> void:
	## 库内**实际出现**的每个变体轴都必须同时有主题席与纹理事席。
	##
	## 为什么不去"预先给全部 13 个轴补席位"（z1 镜像 / z4 行锁 / z5 等差 目前都没有）：
	## 为**尚未生成关卡**的轴发明视觉身份是本末倒置 —— 玩家看不到，改版时却要一起维护，
	## 而且会掩盖"真的漏了一轴"这种情况。正确做法是**让缺口在出现的那一刻就红灯**：
	## 将来一旦生成 z1/z4/z5 的关卡，这条断言立刻失败并点名（z3 当初就是这么被发现的）。
	##
	## 与 test_variant_axis_tables_cover_the_same_axes 的分工：那条查**两张表之间**是否对齐，
	## 这条查**表与数据之间**是否对齐。
	var missing: Array[String] = []
	var seen: Array[String] = []
	for info: Dictionary in _variant_levels():
		var vid := str(info["vid"])
		if seen.has(vid):
			continue
		seen.append(vid)
		var lacks: Array[String] = []
		if not ThemeMarks.BY_VARIANT.has(vid):
			lacks.append("主题")
		if not TextureMarks.BY_VARIANT.has(vid):
			lacks.append("纹理")
		if not lacks.is_empty():
			missing.append("%s（缺 %s）" % [vid, "+".join(lacks)])
	assert_gt(seen.size(), 0, "库里应有变体关")
	assert_eq(missing.size(), 0,
		"以下变体轴已经在关卡库里出现，但还没有识别通道 —— 请在 tools/theme_marks.gd 与 tools/texture_marks.gd 补席位：%s" % str(missing))


func test_variant_axis_tables_cover_the_same_axes() -> void:
	## 主题表与纹理表的变体席位应一致（同一批变体，两条识别通道不该有缺口）。
	## 缺口会让某个变体「有颜色没徽记」或反之 —— 识别通道不完整。
	var missing_tex: Array[String] = []
	var missing_theme: Array[String] = []
	# 库内实有的变体轴都该有两条识别通道（主题 + 徽记）。
	# z3 原先只有主题（四象限徽记未登记），2026-09-24 补了 `quad` ⇒ 白名单已删除，
	# 现在这条断言是**满覆盖**的：任何在用的变体缺一条通道都会红灯。
	for vid: String in ThemeMarks.BY_VARIANT:
		if not TextureMarks.BY_VARIANT.has(vid):
			missing_tex.append(vid)
	for vid: String in TextureMarks.BY_VARIANT:
		if not ThemeMarks.BY_VARIANT.has(vid):
			missing_theme.append(vid)
	assert_eq(missing_theme.size(), 0, "这些变体有纹理无主题：%s" % str(missing_theme))
	assert_eq(missing_tex.size(), 0,
		"这些变体有主题但无纹理事席（识别通道不完整）：%s" % str(missing_tex))


func test_names_and_descs_free_of_legacy_nicknames() -> void:
	## 全库 name/desc 不得残留**旧昵称**（2026-09-25 补，堵 desc 盲区）。
	##
	## 背景：2026-09-24 已把 122 处名字统一到 display_name，但当时契约只查 name 后缀；
	## 第三轮交叉验证换维度扫 desc，抓出 vg_ring_s6 / vg_trihex_s6 的 desc 仍写
	## 「S6 偶偶约束」—— desc 会写进关卡数据，**同样玩家可见**（选关页/详情）。
	##
	## 词表口径：
	##   · 「骨牌」**不在**表内 —— 它是官方名「骨牌边界」的子串，会整族误报。
	##   · 「洋葱/局部禁形/重心/无环/行列凸/度偶数/分量数/相邻行锁」等官方名也不在表内。
	##   · 若将来某条 desc 的正常中文措辞撞了词表（如「步步紧逼」），改措辞即可 ——
	##     与其放宽门禁，不如让玩家可见文本避开这些易混淆的旧叫法。
	const LEGACY_NICKS: Array[String] = [
		"不行", "稳稳", "散散", "层层", "连排", "偶偶", "块块", "步步"]
	var bad: Array[String] = []
	var checked := 0
	for path in LevelLoader.list_levels():
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var d: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if not (d is Dictionary):
			continue
		var lv: Dictionary = d
		checked += 1
		for field: String in ["name", "desc"]:
			var text := str(lv.get(field, ""))
			for nick: String in LEGACY_NICKS:
				if text.contains(nick):
					bad.append("%s 的 %s 残留旧昵称「%s」：%s" % [
						path.get_file(), field, nick, text])
	assert_gt(checked, 0, "应至少检查到一个关卡")
	assert_eq(bad.size(), 0,
		"玩家可见文本残留旧昵称（应统一为 VariantCatalog.display_name）：\n%s" % "\n".join(bad))
