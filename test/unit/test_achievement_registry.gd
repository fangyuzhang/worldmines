# test_achievement_registry.gd —— AchievementRegistry 测试（文档 23 号 §14.11）
extends GutTest


func test_register_and_check() -> void:
	var a := AchievementRegistry.new()
	assert_true(a.register("first_win", {"name": "首胜"}, func(ctx): return ctx.get("won", false)), "注册应成功")
	var newly := a.check({"won": true})
	assert_eq(newly.size(), 1, "达成后 check 应返回 1 个新成就")
	assert_true(a.is_unlocked("first_win"), "应标记已解锁")


func test_newly_unlocked_only() -> void:
	var a := AchievementRegistry.new()
	a.register("x", {"name": "X"}, func(_ctx): return true)
	a.check({})
	var again := a.check({})
	assert_eq(again.size(), 0, "已解锁的不再重复返回")


func test_list() -> void:
	var a := AchievementRegistry.new()
	a.register("x", {"name": "X"}, func(_ctx): return false)
	assert_eq(a.list().size(), 1, "list 应含一项")
	assert_false(a.list()[0]["unlocked"], "未解锁状态为 false")


func test_invalid() -> void:
	var a := AchievementRegistry.new()
	assert_false(a.register("x", {}, Callable()), "无效 trigger 应拒绝")
	assert_false(a.is_unlocked("nope"), "未注册 is_unlocked 返回 false")


# ============ 内置目录装配 / 解锁集落盘（2026-10-09 成就墙） ============

const Catalog := preload("res://core/achievement_catalog.gd")


func _tmp_path() -> String:
	return "user://test_ach_%d_%d.json" % [Time.get_ticks_usec(), randi()]


func _drop(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_load_catalog_registers_all_builtin() -> void:
	var a := AchievementRegistry.new()
	var n := a.load_catalog(Catalog.all())
	assert_eq(n, Catalog.count(), "内置目录应全部注册成功")
	assert_eq(a.total_count(), Catalog.count(), "注册表条目数应与目录一致")


func test_load_catalog_is_idempotent() -> void:
	var a := AchievementRegistry.new()
	a.load_catalog(Catalog.all())
	var second := a.load_catalog(Catalog.all())
	assert_eq(second, 0, "重复装配应全部跳过（幂等），不得重复计数")
	assert_eq(a.total_count(), Catalog.count(), "条目数不得翻倍")


func test_catalog_progress_by_group() -> void:
	var a := AchievementRegistry.new()
	a.load_catalog(Catalog.all())
	var prog := a.progress_by_group()
	var sum_total := 0
	for g in prog:
		sum_total += int((prog[g] as Dictionary)["total"])
	assert_eq(sum_total, Catalog.count(), "分组总数应覆盖全部成就")
	assert_true(prog.has("illusion"), "应有错觉收藏分组")


func test_save_and_load_roundtrip() -> void:
	var path := _tmp_path()
	var ctx := {"won": true, "stars": 3, "cleared_count": 120, "cleared_no_hint": 60,
		"cleared_axis": {"o1": 3}, "obs_kinds": 10, "struct_kinds": 7, "cons_kinds": 5,
		"illusion_cleared": 24, "illusion_series_kinds": 6,
		"illusion_series_cleared": {"iso": 5, "ani": 3, "holed": 3, "ring": 3, "fold": 3, "wormhole": 3},
		"tutorials_seen": 40, "craft_mods": 4, "craft_published": 4, "craft_feedback": 6}
	var a := AchievementRegistry.new()
	a.load_catalog(Catalog.all())
	var newly := a.check_and_save(ctx, path)
	assert_gt(newly.size(), 0, "该上下文应至少解锁一条")
	assert_true(FileAccess.file_exists(path), "有新解锁时应落盘")

	var b := AchievementRegistry.new()
	b.load_catalog(Catalog.all())
	var restored := b.load_state(path)
	assert_eq(restored, newly.size(), "读回条数应与写出条数一致")
	assert_eq(b.unlocked_count(), a.unlocked_count(), "两边解锁数应一致")
	assert_true(b.is_unlocked(str(newly[0])), "首条新解锁应被读回")
	_drop(path)


func test_check_without_new_unlock_does_not_write() -> void:
	var path := _tmp_path()
	var a := AchievementRegistry.new()
	a.load_catalog(Catalog.all())
	var first := a.check_and_save({}, path)
	assert_eq(first.size(), 0, "空上下文无新解锁")
	assert_false(FileAccess.file_exists(path), "无新解锁时不得写盘（避免每次开局都刷盘）")
	_drop(path)


func test_load_state_tolerates_missing_and_broken() -> void:
	var a := AchievementRegistry.new()
	a.load_catalog(Catalog.all())
	assert_eq(a.load_state("user://no_such_ach_file_xyz.json"), 0, "文件缺失应返回 0 且不报错")

	var path := _tmp_path()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{ 这不是 JSON")
	f.close()
	assert_eq(a.load_state(path), 0, "损坏档应静默跳过")
	assert_eq(a.unlocked_count(), 0, "损坏档不得误解锁")
	_drop(path)


func test_load_state_ignores_unknown_ids() -> void:
	var path := _tmp_path()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "unlocked": ["first_win", "mod_ghost_id"]}))
	f.close()
	var a := AchievementRegistry.new()
	a.load_catalog(Catalog.all())
	assert_eq(a.load_state(path), 1, "只恢复已知 id")
	assert_true(a.is_unlocked("first_win"), "已知 id 应恢复")
	assert_false(a.is_unlocked("mod_ghost_id"), "未知 id 不得被登记为已解锁")
	_drop(path)


func test_clear_resets_defs_and_unlocked() -> void:
	var a := AchievementRegistry.new()
	a.register("x", {"name": "X"}, func(_ctx): return true)
	a.check({})
	assert_eq(a.unlocked_count(), 1, "前置：应已解锁")
	a.clear()
	assert_eq(a.total_count(), 0, "clear 应清空定义")
	assert_eq(a.unlocked_count(), 0, "clear 应清空解锁状态")
