# test_stats_registry.gd —— StatsRegistry 测试（文档 23 号 §14.11）
extends GutTest


func test_register_and_add() -> void:
	var s := StatsRegistry.new()
	assert_true(s.register_dimension("chains", "sum"), "注册维度应成功")
	assert_eq(s.get_value("chains"), 0, "初始为 0")
	s.add("chains")
	assert_eq(s.get_value("chains"), 1, "默认 +1")
	s.add("chains", 5)
	assert_eq(s.get_value("chains"), 6, "累计 +5")


func test_add_float() -> void:
	var s := StatsRegistry.new()
	s.register_dimension("time", "sum")
	s.add("time", 1.5)
	s.add("time", 2.5)
	assert_eq(s.get_value("time"), 4.0, "浮点累计")


func test_list_and_unknown() -> void:
	var s := StatsRegistry.new()
	s.register_dimension("a", "sum")
	assert_eq(s.list().size(), 1, "list 应含一项")
	assert_eq(s.get_value("nope"), null, "未注册读 null")


func test_reject_duplicate() -> void:
	var s := StatsRegistry.new()
	s.register_dimension("k", "sum")
	assert_false(s.register_dimension("k", "max"), "重复注册应失败")
