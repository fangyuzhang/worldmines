# test_difficulty_registry.gd —— DifficultyRegistry 测试（文档 23 号 §14.11）
extends GutTest


func test_register_and_compute() -> void:
	var d := DifficultyRegistry.new()
	assert_true(d.register_metric("chain_len", func(ctx): return ctx.get("len", 0) * 2), "注册维度应成功")
	assert_eq(d.compute("chain_len", {"len": 3}), 6, "compute 应调用函数")


func test_compute_all() -> void:
	var d := DifficultyRegistry.new()
	d.register_metric("a", func(_ctx): return 1)
	d.register_metric("b", func(_ctx): return 2)
	var all := d.compute_all({})
	assert_eq(all["a"], 1, "compute_all 含 a")
	assert_eq(all["b"], 2, "compute_all 含 b")


func test_invalid_callable() -> void:
	var d := DifficultyRegistry.new()
	assert_false(d.register_metric("x", Callable()), "无效 Callable 应拒绝")
	assert_eq(d.compute("nope", {}), null, "未注册 compute 返回 null")
