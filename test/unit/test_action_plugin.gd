# test_action_plugin.gd —— ActionPlugin 测试（文档 23 号 §15.7）
extends GutTest


class DecodeFlag extends ActionPlugin:
	func get_action_id() -> StringName:
		return &"decode_flag"
	func is_applicable(_view: PlayerView, _ctx: Variant = null) -> bool:
		return true


func test_base_defaults() -> void:
	var a := ActionPlugin.new()
	assert_eq(a.get_action_id(), &"", "基类动作 id 为空")
	assert_false(a.is_applicable(null), "基类动作不可用")


func test_custom_action() -> void:
	var a := DecodeFlag.new()
	assert_eq(a.get_action_id(), &"decode_flag", "自定义动作 id")
	assert_true(a.is_applicable(null), "自定义动作可用")


func test_register_via_plugin_manager() -> void:
	var pm := PluginManager.new()
	pm.declare_point(&"ActionPlugin", ["is_applicable", "apply_to_player_view"])
	assert_true(pm.register(&"ActionPlugin", DecodeFlag.new()), "动作可作为扩展点注册")
