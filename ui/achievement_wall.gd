# achievement_wall.gd —— 成就墙（按组展示 78 条内置成就 + Mod 成就）
#
# 版式：顶部总进度 → 每组一节（组名 + 说明 + 已解锁/总数）→ 组内两列卡片。
# 卡片在**未解锁**时降透明度（不给假信息：完全隐藏条目会让玩家不知道有什么可做，
# 而扫雷的成就大多是「换个方式再打一遍」，看得见才构成目标）。
#
# ⚠️ 刻意不写 class_name（坑表 #26）。入口：`AchievementWall.open(host)`，host 需能覆盖全屏。
extends RefCounted


const Shell := preload("res://ui/tool_shell.gd")
const Catalog := preload("res://core/achievement_catalog.gd")
const Service := preload("res://ui/achievement_service.gd")


static func open(host: Control) -> Control:
	# 打开即刷新一次：成就墙是玩家「看自己做到哪了」的地方，显示上一次判定之后的旧状态
	# 会直接读成 bug（例如刚读完教学却还显示未解锁）。
	Service.refresh()
	var reg = Service.registry()
	var sh := Shell.build(host, "成就墙",
		"已解锁 %d / %d —— 错觉收藏 %d 关、教学 %d 页都算在里面" % [
			reg.unlocked_count(), reg.total_count(),
			Service.illusion_total(), Service.registry().total_count()])
	if sh.is_empty():
		return null
	var body: VBoxContainer = sh["body"]
	var prog: Dictionary = reg.progress_by_group()

	# 总进度
	var bar := ProgressBar.new()
	bar.name = "AchievementTotal"
	var total := maxi(reg.total_count(), 1)
	bar.max_value = float(total)
	bar.value = float(reg.unlocked_count())
	bar.custom_minimum_size = Vector2(0, 18)
	bar.set_meta("ach_total", true)
	body.add_child(bar)

	for g in Catalog.groups():
		var gid := str(g["id"])
		var stat: Dictionary = prog.get(gid, {"unlocked": 0, "total": 0})
		body.add_child(Shell.section_header(str(g["name"]), str(g["desc"]),
			"%d / %d" % [int(stat["unlocked"]), int(stat["total"])]))
		var grid := GridContainer.new()
		grid.name = "AchGrid_" + gid
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 8)
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for d in Catalog.all():
			if str(d.get("group", "")) != gid:
				continue
			grid.add_child(card(d, reg.is_unlocked(str(d["id"]))))
		body.add_child(grid)

	# Mod 注册的成就（无 group）单列一节 —— 内置墙与 Mod 成就共用同一套渲染。
	if prog.has("other"):
		var stat2: Dictionary = prog["other"]
		body.add_child(Shell.section_header("Mod 成就", "由 Mod 注册的成就",
			"%d / %d" % [int(stat2["unlocked"]), int(stat2["total"])]))
		var grid2 := GridContainer.new()
		grid2.name = "AchGrid_other"
		grid2.columns = 2
		grid2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for entry in reg.list():
			if str(entry.get("group", "")) != "":
				continue
			grid2.add_child(card(entry, bool(entry.get("unlocked", false))))
		body.add_child(grid2)

	body.add_child(Shell.note("提示：成就只记录「你做到过」，失败不会扣掉任何一条。"))
	return sh["root"] as Control


## 一条成就卡。meta 供测试/调试定位（ach_id / ach_unlocked）。
static func card(d: Dictionary, unlocked: bool) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_lb := Label.new()
	name_lb.text = ("★ " if unlocked else "☆ ") + str(d.get("name", str(d.get("id", ""))))
	name_lb.add_theme_font_size_override("font_size", 17)
	box.add_child(name_lb)

	var desc_lb := Label.new()
	desc_lb.text = str(d.get("desc", d.get("description", "")))
	desc_lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lb.add_theme_font_size_override("font_size", 13)
	box.add_child(desc_lb)

	var state := Label.new()
	state.text = "已解锁" if unlocked else "未解锁"
	state.add_theme_font_size_override("font_size", 12)
	box.add_child(state)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.set_meta("ach_id", str(d.get("id", "")))
	panel.set_meta("ach_unlocked", unlocked)
	# 未解锁降透明度：一眼能扫出已解锁的那几块，但仍看得见目标。
	panel.modulate = Color(1, 1, 1, 1.0 if unlocked else 0.62)
	panel.add_child(Shell.padded(box, 9))
	return panel
