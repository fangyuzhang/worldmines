# test_event_bus.gd —— EventBus 测试（文档 23 号 §5 / §14.9）
extends GutTest


class Counter extends RefCounted:
	var count: int = 0
	func bump(_payload: Variant = null) -> void:
		count += 1


class Recorder extends RefCounted:
	var last: Variant = null
	func rec(payload: Variant = null) -> void:
		last = payload


func test_on_emit() -> void:
	var bus := EventBus.new()
	var c := Counter.new()
	bus.on(EventBus.LEVEL_STARTED, c.bump)
	bus.emit(EventBus.LEVEL_STARTED)
	assert_eq(c.count, 1, "emit 应触发已订阅 handler")


func test_off() -> void:
	var bus := EventBus.new()
	var c := Counter.new()
	bus.on(&"e", c.bump)
	bus.off(&"e", c.bump)
	bus.emit(&"e")
	assert_eq(c.count, 0, "取消订阅后不应触发")


func test_dedup() -> void:
	var bus := EventBus.new()
	var c := Counter.new()
	bus.on(&"e", c.bump)
	bus.on(&"e", c.bump)
	assert_eq(bus.listener_count(&"e"), 1, "重复订阅同一 Callable 应去重")


func test_payload() -> void:
	var bus := EventBus.new()
	var r := Recorder.new()
	bus.on(&"e", r.rec)
	bus.emit(&"e", {"pos": Vector2i(2, 3)})
	assert_eq(r.last["pos"], Vector2i(2, 3), "payload 应原样传给 handler")


func test_custom_event() -> void:
	var bus := EventBus.new()
	var c := Counter.new()
	# Mod 自定义事件（23 号 §14.9：带命名空间）
	bus.on(&"mod.hex.rotated", c.bump)
	bus.emit(&"mod.hex.rotated")
	assert_eq(c.count, 1, "自定义事件应可订阅与广播")
	assert_true(bus.list_events().has(&"mod.hex.rotated"), "自定义事件应在 list_events 中")


func test_listener_count() -> void:
	var bus := EventBus.new()
	var a := Counter.new()
	var b := Counter.new()
	bus.on(&"e", a.bump)
	bus.on(&"e", b.bump)
	assert_eq(bus.listener_count(&"e"), 2, "两个不同 handler 应计数 2")
	assert_true(bus.has(&"e"), "has 应返回 true")
	assert_false(bus.has(&"none"), "未订阅事件 has 应返回 false")
