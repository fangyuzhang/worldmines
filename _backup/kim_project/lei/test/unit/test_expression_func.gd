# test_expression_func.gd —— ExpressionFuncRegistry 测试（文档 23 号 §14.5）
extends GutTest


func test_register_call() -> void:
	var r := ExpressionFuncRegistry.new()
	assert_true(r.register("dist", func(a, b): return abs(int(a) - int(b)), true), "注册应成功")
	assert_eq(r.invoke("dist", [3, 8]), 5, "invoke 应执行函数")


func test_symbolizable() -> void:
	var r := ExpressionFuncRegistry.new()
	r.register("pure", func(x): return x, true)
	r.register("blackbox", func(x): return x, false)
	assert_true(r.is_symbolizable("pure"), "纯函数可符号化")
	assert_false(r.is_symbolizable("blackbox"), "黑盒不可符号化")


func test_unknown_and_reject() -> void:
	var r := ExpressionFuncRegistry.new()
	assert_eq(r.invoke("nope", []), null, "未注册 invoke 返回 null")
	assert_false(r.has("nope"), "has 返回 false")
	assert_false(r.register("", func(): pass), "空名应拒绝")
	assert_false(r.register("x", Callable()), "无效 callable 应拒绝")


func test_list() -> void:
	var r := ExpressionFuncRegistry.new()
	r.register("a", func(): pass, true)
	assert_eq(r.list().size(), 1, "list 应含一项")
	assert_true(r.list()[0]["symbolizable"], "list 项含 symbolizable")
