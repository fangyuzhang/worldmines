# test_level_custom_schema.gd —— LevelCustomSchema 测试（文档 23 号 §15.4）
extends GutTest


func test_register_validate() -> void:
	var s := LevelCustomSchema.new()
	assert_true(s.register("workshop.2e@1.0/schema.json", func(c): return c.has("symbols")), "注册应成功")
	assert_true(s.validate("workshop.2e@1.0/schema.json", {"symbols": ["A"]}), "校验通过")
	assert_false(s.validate("workshop.2e@1.0/schema.json", {}), "缺字段校验失败")


func test_unregistered_schema() -> void:
	var s := LevelCustomSchema.new()
	assert_false(s.validate("nope", {"a": 1}), "未注册 schema 校验失败")


func test_list_and_has() -> void:
	var s := LevelCustomSchema.new()
	s.register("a", func(_c): return true)
	assert_true(s.has("a"), "has 返回 true")
	assert_eq(s.list().size(), 1, "list 含一项")


func test_reject_invalid() -> void:
	var s := LevelCustomSchema.new()
	assert_false(s.register("", func(_c): return true), "空 id 应拒绝")
	assert_false(s.register("x", Callable()), "无效 validator 应拒绝")
