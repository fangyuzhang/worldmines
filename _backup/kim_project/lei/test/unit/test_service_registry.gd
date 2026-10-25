# test_service_registry.gd —— ServiceRegistry 测试（文档 23 号 §14.3）
extends GutTest


class FakeMath extends RefCounted:
	var value: int = 0


func test_provide_get() -> void:
	var reg := ServiceRegistry.new()
	var m := FakeMath.new()
	reg.provide(&"hex.HexGridMath", m)
	assert_eq(reg.get_service(&"hex.HexGridMath"), m, "provide 后 get 应返回 impl")


func test_get_missing() -> void:
	var reg := ServiceRegistry.new()
	assert_eq(reg.get_service(&"hex.Nonexistent"), null, "未提供服务应返回 null（消费方走 fallback）")


func test_version_major_mismatch() -> void:
	var reg := ServiceRegistry.new()
	reg.provide(&"hex.HexGridMath", FakeMath.new(), "1.0.0")
	assert_eq(reg.get_service(&"hex.HexGridMath", "2.0.0"), null, "major 不兼容应返回 null")


func test_version_satisfies() -> void:
	var reg := ServiceRegistry.new()
	var m := FakeMath.new()
	reg.provide(&"hex.HexGridMath", m, "1.5.0")
	assert_eq(reg.get_service(&"hex.HexGridMath", "1.2.0"), m, "minor 更高应满足要求")
	assert_eq(reg.get_service(&"hex.HexGridMath", "1.5.0"), m, "版本相等应满足")
	assert_eq(reg.get_service(&"hex.HexGridMath", "1.6.0"), null, "patch 更低不满足要求")


func test_unprovide() -> void:
	var reg := ServiceRegistry.new()
	reg.provide(&"s", FakeMath.new())
	assert_true(reg.unprovide(&"s"), "unprovide 应成功")
	assert_eq(reg.get_service(&"s"), null, "移除后 get 应为 null")
	assert_false(reg.unprovide(&"s"), "重复 unprovide 应返回 false")


func test_has_info_list() -> void:
	var reg := ServiceRegistry.new()
	var m := FakeMath.new()
	reg.provide(&"hex.HexGridMath", m, "2.0.0", &"hexworks")
	assert_true(reg.has(&"hex.HexGridMath"), "has 应返回 true")
	assert_eq(reg.info(&"hex.HexGridMath")["version"], "2.0.0", "info 应带版本")
	assert_eq(reg.info(&"hex.HexGridMath")["provider"], &"hexworks", "info 应带提供方")
	assert_true(reg.list_services().has(&"hex.HexGridMath"), "list_services 应包含已注册服务")


func test_overwrite() -> void:
	var reg := ServiceRegistry.new()
	var a := FakeMath.new()
	var b := FakeMath.new()
	reg.provide(&"s", a, "1.0.0")
	reg.provide(&"s", b, "1.1.0")
	assert_eq(reg.get_service(&"s"), b, "重复 provide 应覆盖为最新")
	assert_eq(reg.info(&"s")["version"], "1.1.0", "版本应更新")


func test_reject_null() -> void:
	var reg := ServiceRegistry.new()
	assert_false(reg.provide(&"s", null), "impl 为 null 应拒绝")
	assert_false(reg.provide(&"", FakeMath.new()), "service_id 为空应拒绝")


func test_provide_reject_hijack() -> void:
	var reg := ServiceRegistry.new()
	assert_true(reg.provide(&"s", FakeMath.new(), "1.0.0", &"modA"), "modA 首次提供应成功")
	assert_false(reg.provide(&"s", FakeMath.new(), "1.0.0", &"modB"), "modB 劫持同名服务应被拒")
	assert_true(reg.provide(&"s", FakeMath.new(), "2.0.0", &"modA"), "同提供方更新应允许")
	assert_eq(reg.info(&"s")["provider"], &"modA", "提供方应保持 modA")
