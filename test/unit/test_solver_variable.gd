# test_solver_variable.gd —— SolverVariablePlugin 测试（文档 23 号 §15.3）
extends GutTest


class IntVar extends SolverVariablePlugin:
	func get_var_id() -> StringName:
		return &"temperature"
	func domain_kind() -> int:
		return DOMAIN_INT_RANGE
	func int_range() -> Vector2i:
		return Vector2i(0, 100)


func test_base_defaults() -> void:
	var v := SolverVariablePlugin.new()
	assert_eq(v.get_var_id(), &"", "基类 var_id 为空")
	assert_eq(v.domain_kind(), SolverVariablePlugin.DOMAIN_BOOLEAN, "基类默认 BOOLEAN")


func test_custom_variable() -> void:
	var v := IntVar.new()
	assert_eq(v.get_var_id(), &"temperature", "自定义 var_id")
	assert_eq(v.domain_kind(), SolverVariablePlugin.DOMAIN_INT_RANGE, "自定义 domain_kind")
	assert_eq(v.int_range(), Vector2i(0, 100), "自定义 int_range")


func test_register_via_plugin_manager() -> void:
	var pm := PluginManager.new()
	pm.declare_point(&"SolverVariable", ["domain_kind", "propagate"])
	assert_true(pm.register(&"SolverVariable", IntVar.new()), "变量可作为扩展点注册")
