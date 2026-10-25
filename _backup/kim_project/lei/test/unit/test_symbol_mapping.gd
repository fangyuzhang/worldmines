# test_symbol_mapping.gd —— SymbolMappingConstraint 测试（文档 23 号 §15.2）
extends GutTest


class LetterMap extends SymbolMappingConstraint:
	func get_mapping_id() -> StringName:
		return &"letter2digit"
	func symbols() -> Array[StringName]:
		var out: Array[StringName] = [&"A", &"B", &"C"]
		return out
	func value_domain() -> Vector2i:
		return Vector2i(0, 2)
	func mapping_kind() -> int:
		return MAPPING_BIJECTION


func test_base_coupling() -> void:
	var m := SymbolMappingConstraint.new()
	assert_eq(m.coupling_kind(), ConstraintPlugin.COUPLING_SYMBOL_MAPPING, "耦合类型应为 SYMBOL_MAPPING")


func test_custom_mapping() -> void:
	var m := LetterMap.new()
	assert_eq(m.get_mapping_id(), &"letter2digit", "自定义映射 id")
	assert_eq(m.symbols().size(), 3, "符号集合 3 个")
	assert_eq(m.value_domain(), Vector2i(0, 2), "值域")
	assert_eq(m.mapping_kind(), SymbolMappingConstraint.MAPPING_BIJECTION, "BIJECTION 映射")


func test_register_as_constraint() -> void:
	var pm := PluginManager.new()
	pm.declare_point(&"ConstraintPlugin", ["check", "coupling_kind"])
	assert_true(pm.register(&"ConstraintPlugin", LetterMap.new()), "符号映射约束可作为约束插件注册")
	var impl: ConstraintPlugin = pm.first(&"ConstraintPlugin")
	assert_eq(impl.coupling_kind(), ConstraintPlugin.COUPLING_SYMBOL_MAPPING, "注册后耦合类型正确")
