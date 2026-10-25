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
