# test_plugin_manager.gd —— PluginManager 测试（文档 23 号 §三 / §14.2 / 21 号 R33）
extends GutTest


class FakeClue extends RefCounted:
	var _id: StringName
	func _init(id: StringName) -> void:
		_id = id
	func get_id() -> StringName:
		return _id
	func value_range(_ctx: Variant = null) -> Vector2i:
		return Vector2i(0, 8)
	func compute(_view: Variant, _pos: Variant, _ctx: Variant = null) -> Variant:
		return 0


class BadClue extends RefCounted:
	var _id: StringName
	func _init(id: StringName) -> void:
		_id = id
	func get_id() -> StringName:
		return _id
	# 缺少 value_range / compute


class FakeRenderer extends RefCounted:
	func get_id() -> StringName:
		return &"r1"
	func render(_frame: Variant) -> void:
		pass
	func supports() -> bool:
		return true


func test_declare_and_register() -> void:
	var pm := PluginManager.new()
	pm.declare_point(&"CluePlugin", ["value_range", "compute"])
	var c := FakeClue.new(&"c1")
	assert_true(pm.register(&"CluePlugin", c), "契约满足应注册成功")
	assert_eq(pm.first(&"CluePlugin"), c, "get 应返回已注册实现")


func test_contract_validation() -> void:
	var pm := PluginManager.new()
	pm.declare_point(&"CluePlugin", ["value_range", "compute"])
	var bad := BadClue.new(&"bad")
	assert_false(pm.register(&"CluePlugin", bad), "缺必需方法应拒绝注册")
	assert_eq(pm.first(&"CluePlugin"), null, "拒绝后 get 应为 null")


func test_priority_ordering() -> void:
	var pm := PluginManager.new()
	pm.declare_point(&"CluePlugin", ["value_range", "compute"])
	var low := FakeClue.new(&"low")
	var high := FakeClue.new(&"high")
	pm.register(&"CluePlugin", low, 50)
	pm.register(&"CluePlugin", high, 90)
	assert_eq(pm.first(&"CluePlugin"), high, "get 应返回高优先级")
	var all_impls := pm.all(&"CluePlugin")
	assert_eq(all_impls[0], high, "all 首元素应为高优先级")
	assert_eq(all_impls[1], low, "all 次元素应为低优先级")


func test_idempotent_reregister() -> void:
	var pm := PluginManager.new()
	pm.declare_point(&"CluePlugin", ["value_range", "compute"])
	var a := FakeClue.new(&"same")
	var b := FakeClue.new(&"same")
	pm.register(&"CluePlugin", a, 10)
	pm.register(&"CluePlugin", b, 20)
	assert_eq(pm.all(&"CluePlugin").size(), 1, "同 id 重复注册应覆盖而非叠加")
	assert_eq(pm.first(&"CluePlugin"), b, "覆盖后应为最新实现")


func test_unregister_and_fallback() -> void:
	var pm := PluginManager.new()
	pm.declare_point(&"CluePlugin", ["value_range", "compute"])
	var a := FakeClue.new(&"a")
	var b := FakeClue.new(&"b")
	pm.register(&"CluePlugin", a, 90)
	pm.register(&"CluePlugin", b, 80)
	assert_true(pm.unregister(&"CluePlugin", &"a"), "注销应成功")
	assert_eq(pm.first(&"CluePlugin"), b, "注销后 get 应回退到下一个")
	assert_eq(pm.next(&"CluePlugin", b), null, "无下一个时 next 返回 null")


func test_self_bootstrapped_point() -> void:
	var pm := PluginManager.new()
	# Mod 自举声明一个全新扩展点（R33：平台不得垄断定义扩展点的权力）
	pm.declare_point(&"hexworks.ReplayRenderer", ["render", "supports"])
	var r := FakeRenderer.new()
	assert_true(pm.register(&"hexworks.ReplayRenderer", r), "自举扩展点应可注册实现")
	assert_eq(pm.first(&"hexworks.ReplayRenderer"), r, "自举扩展点应可取到实现")
	assert_true(pm.list_points().has(&"hexworks.ReplayRenderer"), "自举扩展点应在 list_points 中")
