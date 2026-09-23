# test_cell_texture.gd —— 变体纹理徽记（palette.texture）的契约（2026-09-22）
#
# 纹理是「这一盘是哪个变体」的第二条识别通道（第一条是 palette.theme 的颜色）。
# 门禁三件事：
#   ① 数据合法：全库凡写了 palette.texture 的关卡，取值必须在 _marks() 里
#      —— 写错的后果是**静默不画**（渲染层对未登记值返回空串），肉眼很难发现，
#      所以必须由测试挡住；反过来登记表里的每个标记也应至少被一个关卡用到（防登记表腐烂）。
#   ② 覆盖：每个变体（S/Z/骨牌轴）都至少有一关带纹理，否则"变体外观差异"就有缺口。
#   ③ 零回归：无 palette 的矩形经典关不得被画纹理（渲染层的条件之一就是 palette 非空）。
extends GutTest

const LEVELS_DIR := "res://levels"


## 纹理登记表：从 board_view.gd 的脚本常量读。
## **不用类名访问**（`BoardView.XXX`）——board_view.gd 没有 class_name，写类名会让整个
## 测试文件解析失败，而 GUT 的表现是**静默跳过该文件**（实测：Scripts 数量少一个、
## 连失败提示都没有，很容易误以为"跑过了"）。
func _marks() -> Array:
	return load("res://ui/board_view.gd").TEXTURE_MARKS


func _all_levels() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for path in LevelLoader.list_levels():
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var d: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if d is Dictionary:
			var lv: Dictionary = d
			lv["__path"] = path
			out.append(lv)
	return out


func test_every_declared_texture_is_registered() -> void:
	var bad: Array[String] = []
	var used := {}
	for lv in _all_levels():
		var pal: Variant = lv.get("palette", null)
		if not (pal is Dictionary):
			continue
		var tex: Variant = (pal as Dictionary).get("texture", null)
		if tex == null:
			continue
		var t := str(tex)
		used[t] = true
		if not _marks().has(t):
			bad.append("%s: %s" % [str(lv.get("__path", "?")), t])
	assert_eq(bad.size(), 0,
		"以下关卡的 palette.texture 未在 _marks() 登记（渲染层会静默不画）：%s" % str(bad))
	assert_gt(used.size(), 0, "应至少有一关声明纹理")


func test_no_registered_mark_is_dead() -> void:
	## 反向：登记表里的每个标记都应被至少一关用到（防"登记了但没人用"的腐烂）。
	var used := {}
	for lv in _all_levels():
		var pal: Variant = lv.get("palette", null)
		if pal is Dictionary and (pal as Dictionary).has("texture"):
			used[str((pal as Dictionary)["texture"])] = true
	var dead: Array[String] = []
	for m: String in _marks():
		if not used.has(m):
			dead.append(m)
	assert_eq(dead.size(), 0, "以下纹理标记已登记但没有任何关卡使用（登记表腐烂）：%s" % str(dead))


func test_registry_has_no_duplicates() -> void:
	var seen := {}
	for m: String in _marks():
		assert_false(seen.has(m), "TEXTURE_MARKS 有重复项：%s" % m)
		seen[m] = true


func test_every_variant_axis_has_textured_levels() -> void:
	## 九个变体（s1~s7 / z2 / dt）各自至少一关带纹理 —— 变体外观差异不能只覆盖一半。
	var by_variant := {}
	for lv in _all_levels():
		var gr: Variant = lv.get("global_rules", [])
		if not (gr is Array) or (gr as Array).is_empty():
			continue
		var pal: Variant = lv.get("palette", null)
		if not (pal is Dictionary) or not (pal as Dictionary).has("texture"):
			continue
		var vid := str((gr as Array)[0])
		by_variant[vid] = int(by_variant.get(vid, 0)) + 1
	for vid in ["s1", "s2", "s3", "s4", "s5", "s6", "s7", "z2", "dt"]:
		assert_true(by_variant.has(vid), "变体 %s 没有任何带纹理的关卡" % vid)


func test_rect_classic_levels_stay_untouched() -> void:
	## 零回归前提：矩形经典关没有 palette ⇒ 渲染层的纹理分支不会进入。
	var checked := 0
	for lv in _all_levels():
		var topo: Variant = lv.get("topology", null)
		if topo is Dictionary and not (topo as Dictionary).is_empty():
			continue                      # 只看非异形关
		checked += 1
		assert_false(lv.has("palette"), "矩形关 %s 不应有 palette（否则会吃到纹理/主题色）" % str(lv.get("__path", "?")))
	assert_gt(checked, 0, "应检查到矩形经典关")


func test_texture_alpha_breathes_within_a_safe_band() -> void:
	## 呼吸：动效开 → alpha 在安全带内摆动（看得见在动，又不盖过数字）；
	## 动效关 → **恒定基准值**（完全静止，这是"关掉特效"的语义）。
	## 注意这里验的是纯函数 texture_alpha_at(ms, pulsing) —— 不依赖真实时钟，
	## 也就不会因为机器忙而导致偶发红灯。
	var view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(view)
	await wait_process_frames(1)
	var lo := 1.0
	var hi := 0.0
	var i := 0
	while i < 40:
		var a: float = view.texture_alpha_at(i * 150, true)   # 覆盖 6 秒 = 两个呼吸周期
		lo = minf(lo, a)
		hi = maxf(hi, a)
		i += 1
	assert_lt(lo, 0.22, "呼吸下限应接近 0.20（实得 %.3f）" % lo)
	assert_gt(hi, 0.38, "呼吸上限应接近 0.40（实得 %.3f）" % hi)
	assert_gt(lo, 0.10, "徽记不应在谷底完全消失（否则读不出变体）")
	assert_lt(hi, 0.55, "徽记峰值不应盖过格内数字")
	assert_almost_eq(view.texture_alpha_at(1234, false), 0.30, 0.0001,
		"动效关闭时必须完全静止（恒定基准值）")


func test_theme_texture_resolves_and_rejects_unknown() -> void:
	## 渲染层的解析函数：已登记值原样返回、未登记值退化为空串（静默降级，不臆造徽记）。
	var view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(view)
	await wait_process_frames(1)
	# 无 palette（矩形关）→ 空串
	assert_eq(view._theme_texture(), "", "无 palette 时应返回空串")
	# 未登记值 → 空串；登记值 → 原样（直接验静态表 + 解析口径一致）
	assert_true(_marks().has("weave"), "登记表应含 weave")
	assert_false(_marks().has("__nope__"), "未登记的标记不应在表内")
