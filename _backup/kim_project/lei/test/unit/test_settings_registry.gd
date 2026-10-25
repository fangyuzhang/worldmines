# test_settings_registry.gd —— SettingsRegistry 测试（文档 23 号 §14.11）
extends GutTest


func test_register_get_set() -> void:
	var s := SettingsRegistry.new()
	assert_true(s.register("my_toggle", "bool", false, "我的开关"), "注册应成功")
	assert_eq(s.get_value("my_toggle"), false, "读默认值")
	s.set_value("my_toggle", true)
	assert_eq(s.get_value("my_toggle"), true, "写值后读取")


func test_reset() -> void:
	var s := SettingsRegistry.new()
	s.register("k", "int", 5, "x")
	s.set_value("k", 99)
	s.reset("k")
	assert_eq(s.get_value("k"), 5, "重置回默认")


func test_list() -> void:
	var s := SettingsRegistry.new()
	s.register("a", "int", 1, "A")
	s.register("b", "bool", true, "B")
	assert_eq(s.list().size(), 2, "list 应含两项")
	assert_eq(s.list()[0]["label"], "A", "list 项应含 label")


func test_reject_duplicate() -> void:
	var s := SettingsRegistry.new()
	s.register("k", "int", 1, "x")
	assert_false(s.register("k", "int", 2, "y"), "重复注册应失败")
	assert_false(s.register("", "int", 0, "z"), "空 id 应失败")
