# test_theme_token.gd —— ThemeTokenRegistry 测试（文档 23 号 §14.10）
extends GutTest


func test_declare_and_read() -> void:
	var t := ThemeTokenRegistry.new()
	assert_true(t.declare_token(&"cell.border_width", 2), "声明 token 应成功")
	assert_eq(t.token(&"cell.border_width"), 2, "未覆盖时读默认值")


func test_override() -> void:
	var t := ThemeTokenRegistry.new()
	t.declare_token(&"cell.border_width", 2)
	t.set_override(&"cell.border_width", 4)
	assert_eq(t.token(&"cell.border_width"), 4, "覆盖后读覆盖值")
	assert_true(t.is_overridden(&"cell.border_width"), "应标记为已覆盖")


func test_clear_override() -> void:
	var t := ThemeTokenRegistry.new()
	t.declare_token(&"k", 2)
	t.set_override(&"k", 9)
	t.clear_override(&"k")
	assert_eq(t.token(&"k"), 2, "清除覆盖后回退默认")
	assert_false(t.is_overridden(&"k"), "清除后不再标记覆盖")


func test_defaults() -> void:
	var t := ThemeTokenRegistry.new()
	t.declare_token(&"a", 1)
	t.declare_token(&"b", 2)
	assert_eq(t.defaults()[&"a"], 1, "defaults 应含默认值")
	assert_true(t.list_tokens().has(&"b"), "list_tokens 应含全部")


func test_reject_duplicate() -> void:
	var t := ThemeTokenRegistry.new()
	t.declare_token(&"k", 1)
	assert_false(t.declare_token(&"k", 2), "重复声明应失败")
	assert_false(t.declare_token(&"", 1), "空名应失败")


func test_undeclared_reads_null() -> void:
	var t := ThemeTokenRegistry.new()
	assert_eq(t.token(&"nope"), null, "未声明读 null")
