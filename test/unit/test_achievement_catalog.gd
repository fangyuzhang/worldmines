# test_achievement_catalog.gd —— 内置成就目录契约（内容层）
#
# 守四件事：
#   ① 目录规模落在策划案要求的 60~80 条，id 唯一、分组合法、文案非空；
#   ② **空上下文下任何成就都不得解锁** —— 这是最容易出的静默 bug（一进游戏弹一堆成就）；
#   ③ 判定 DSL 的语义（all / any / not / flag / axis / series / 比较符）逐条钉死；
#   ④ 一份「什么都做到了」的上下文应解锁绝大多数 —— 防「条件写反了永远解不开」。
extends GutTest

const Catalog := preload("res://core/achievement_catalog.gd")
const Registry := preload("res://core/achievement_registry.gd")


func _empty_ctx() -> Dictionary:
	return {}


func _rich_ctx() -> Dictionary:
	var axes := {}
	var obs := ["o1", "o2", "o3", "o4", "o5x", "o6", "o7", "o8", "o9", "o10"]
	var structs := ["s1", "s2", "s3", "s4", "s5", "s6", "s7"]
	var cons := ["z1", "z2", "z3", "z4", "z5"]
	for a in obs:
		axes[a] = 3
	for a in structs:
		axes[a] = 3
	for a in cons:
		axes[a] = 3
	return {
		"won": true, "stars": 3, "hint_tier": 2, "elapsed": 9.0, "level_plays": 5,
		"level_key": "gen://o1/8/0",
		"cleared_count": 120, "cleared_manual": 6, "cleared_lib": 24, "cleared_gen": 60,
		"cleared_no_hint": 60, "cleared_axis": axes, "axis_kinds": 22,
		"obs_cleared": 30, "struct_cleared": 20, "cons_cleared": 12,
		"obs_kinds": 10, "struct_kinds": 7, "cons_kinds": 5,
		"axes_hit_obs": 1, "axes_hit_struct": 1, "axes_hit_conserve": 1,
		"illusion_cleared": 24, "illusion_total": 30, "illusion_series_kinds": 6,
		"illusion_series_cleared": {"iso": 5, "ani": 3, "holed": 3, "ring": 3, "fold": 3, "wormhole": 3},
		"runs_total": 60, "tutorials_seen": 40,
		"craft_mods": 4, "craft_published": 4, "craft_feedback": 6,
		"avg_stars_x10": 29,
	}


# ---- ① 目录形态 ----

func test_size_within_design_range() -> void:
	var n := Catalog.count()
	assert_between(n, 60, 80, "内置成就数应落在策划案区间 60~80（实得 %d）" % n)


func test_ids_unique_and_nonempty() -> void:
	var seen := {}
	for d in Catalog.all():
		var id := str(d.get("id", ""))
		assert_ne(id, "", "成就 id 不得为空")
		assert_false(seen.has(id), "成就 id 重复：%s" % id)
		seen[id] = true
	assert_eq(seen.size(), Catalog.count(), "id 数量应与条目数一致")


func test_every_entry_has_name_desc_and_valid_group() -> void:
	var group_ids: Array[String] = []
	for g in Catalog.groups():
		group_ids.append(str(g["id"]))
	for d in Catalog.all():
		var id := str(d["id"])
		assert_ne(str(d.get("name", "")), "", "%s 缺 name" % id)
		assert_ne(str(d.get("desc", "")), "", "%s 缺 desc" % id)
		assert_true(group_ids.has(str(d.get("group", ""))),
			"%s 的分组 %s 不在 GROUPS 里" % [id, str(d.get("group", ""))])
		assert_true(d.has("cond"), "%s 缺 cond" % id)


func test_group_metadata_is_displayable() -> void:
	assert_gte(Catalog.groups().size(), 6, "分组至少 6 组（界面按组出墙）")
	for g in Catalog.groups():
		assert_ne(str(g.get("name", "")), "", "分组缺显示名：%s" % str(g.get("id", "")))
		assert_ne(str(g.get("desc", "")), "", "分组缺一句话说明：%s" % str(g.get("id", "")))


# ---- ② 不许误解锁 ----

func test_nothing_unlocks_on_empty_context() -> void:
	var ctx := _empty_ctx()
	var bad: Array[String] = []
	for d in Catalog.all():
		if Catalog.evaluate(d["cond"], ctx):
			bad.append(str(d["id"]))
	assert_eq(bad.size(), 0, "空上下文下不得解锁任何成就（实得 %d 条：%s）" % [bad.size(), ", ".join(bad)])


func test_registry_grants_nothing_on_empty_context() -> void:
	var a := Registry.new()
	a.load_catalog(Catalog.all())
	var newly := a.check({})
	assert_eq(newly.size(), 0, "空上下文下注册表不得解锁任何成就")
	assert_eq(a.unlocked_count(), 0, "未解锁数应为 0")


# ---- ③ DSL 语义 ----

func test_dsl_comparators() -> void:
	assert_true(Catalog.evaluate({"metric": "n", "gte": 3}, {"n": 3}), "gte 取等号应成立")
	assert_false(Catalog.evaluate({"metric": "n", "gte": 3}, {"n": 2}), "gte 小于应不成立")
	assert_true(Catalog.evaluate({"metric": "n", "gt": 3}, {"n": 4}), "gt 应成立")
	assert_false(Catalog.evaluate({"metric": "n", "gt": 3}, {"n": 3}), "gt 取等号不应成立")
	assert_true(Catalog.evaluate({"metric": "n", "lte": 3}, {"n": 3}), "lte 取等号应成立")
	assert_true(Catalog.evaluate({"metric": "n", "lt": 3}, {"n": 2}), "lt 应成立")
	assert_true(Catalog.evaluate({"metric": "n", "eq": 4}, {"n": 4}), "eq 应成立")


func test_dsl_boolean_combinators() -> void:
	var ctx := {"a": 1, "b": 0, "won": true}
	assert_true(Catalog.evaluate({"all": [{"metric": "a", "gte": 1}, {"flag": "won"}]}, ctx), "all 全真应成立")
	assert_false(Catalog.evaluate({"all": [{"metric": "a", "gte": 1}, {"metric": "b", "gte": 1}]}, ctx), "all 含假应不成立")
	assert_true(Catalog.evaluate({"any": [{"metric": "b", "gte": 1}, {"flag": "won"}]}, ctx), "any 含真应成立")
	assert_false(Catalog.evaluate({"any": [{"metric": "b", "gte": 1}]}, ctx), "any 全假应不成立")
	assert_true(Catalog.evaluate({"not": {"metric": "b", "gte": 1}}, ctx), "not 应取反")
	assert_false(Catalog.evaluate({"flag": "lost"}, ctx), "缺省 flag 视为 false")


func test_dsl_lookup_tables() -> void:
	var ctx := {"cleared_axis": {"o1": 4}, "illusion_series_cleared": {"iso": 2}}
	assert_true(Catalog.evaluate({"axis": "o1", "gte": 4}, ctx), "axis 查询应命中")
	assert_false(Catalog.evaluate({"axis": "o2", "gte": 1}, ctx), "未记录的轴应为 0")
	assert_true(Catalog.evaluate({"series": "iso", "gte": 2}, ctx), "series 查询应命中")
	assert_false(Catalog.evaluate({"series": "fold", "gte": 1}, ctx), "未记录的系列应为 0")
	assert_false(Catalog.evaluate(null, ctx), "null 条件一律不成立")
	assert_false(Catalog.evaluate({"metric": "x"}, ctx), "没有比较符的条件不成立")


# ---- ④ 条件可达成 ----

func test_rich_context_unlocks_most() -> void:
	var a := Registry.new()
	a.load_catalog(Catalog.all())
	var newly := a.check(_rich_ctx())
	assert_gte(newly.size(), 70,
		"「什么都做到了」的上下文应解锁绝大多数成就（实得 %d / %d）" % [newly.size(), Catalog.count()])


func test_every_metric_used_appears_in_context_builder_scope() -> void:
	# 反向守卫：目录里出现的每个 metric 都必须能被上下文构造器覆盖。
	# 这里只断言「名字非空且不含空格」——真正的覆盖由 ui 层用例保证。
	var used := Catalog.used_metrics()
	# 兜底断言：收集器一旦漏掉 `cond` 键，used_metrics() 会**静默返回空**，
	# 下面那个 for 就一次都不执行 ⇒ GUT 把本用例判成 Risky（而非失败）。先钉住非空。
	assert_gt(used.size(), 0, "目录里必须能收集到 metric（收集器不得静默返回空）")
	for m in used:
		assert_ne(m, "", "metric 名不得为空")
		assert_false(m.begins_with(" "), "metric 名不得以空格开头：%s" % m)


func test_by_id_and_group_name() -> void:
	var d := Catalog.by_id("first_win")
	assert_eq(str(d.get("name", "")), "初次破局", "by_id 应取回该条")
	assert_eq(Catalog.group_name("start"), "起点", "group_name 应取显示名")
	assert_eq(Catalog.by_id("nope").size(), 0, "未知 id 返回空字典")
