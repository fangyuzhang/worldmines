# test_deduction_rule.gd —— DeductionRulePlugin 测试（文档 23 号 §14.8）
extends GutTest


class MyRule extends DeductionRulePlugin:
	func get_rule_id() -> StringName:
		return &"my.even_rule"
	func layer() -> int:
		return 2
	func apply(_view: PlayerView) -> Array:
		return [{"pos": Vector2i(1, 1), "state": "safe", "proof": "测试规则", "sources": []}]


func test_base_defaults() -> void:
	var r := DeductionRulePlugin.new()
	assert_eq(r.get_rule_id(), &"", "基类 rule_id 为空")
	assert_eq(r.layer(), 1, "基类默认 L1")
	assert_eq(r.apply(null), [], "基类 apply 返回空数组")


func test_custom_rule() -> void:
	var r := MyRule.new()
	assert_eq(r.get_rule_id(), &"my.even_rule", "自定义 rule_id")
	assert_eq(r.get_id(), &"my.even_rule", "get_id 映射到 rule_id")
	assert_eq(r.layer(), 2, "自定义 layer")
	var out := r.apply(null)
	assert_eq(out.size(), 1, "apply 返回 1 条结论")
	assert_eq(out[0]["state"], "safe", "结论 state")
	assert_eq(out[0]["pos"], Vector2i(1, 1), "结论 pos")


func test_register_via_plugin_manager() -> void:
	var pm := PluginManager.new()
	pm.declare_point(&"DeductionRule", ["apply", "layer"])
	var r := MyRule.new()
	assert_true(pm.register(&"DeductionRule", r), "推理规则可作为扩展点注册")
	assert_eq(pm.first(&"DeductionRule"), r, "可取到已注册规则")
