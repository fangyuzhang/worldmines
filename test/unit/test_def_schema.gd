# test_def_schema.gd —— DefSchemaRegistry 测试（文档 23 号 §14.7）
extends GutTest


func test_define_and_register() -> void:
	var r := DefSchemaRegistry.new()
	assert_true(r.define_schema(&"weatheref", ["id", "kind"]), "定义 schema 应成功")
	assert_true(r.register_def(&"weatheref", "rainy", {"id": "rainy", "kind": "rain", "weight": 1.0}), "注册应成功")
	assert_eq(r.get_def(&"weatheref", "rainy")["kind"], "rain", "get_def 应返回实例")


func test_register_unknown_type() -> void:
	var r := DefSchemaRegistry.new()
	assert_false(r.register_def(&"nope", "x", {}), "未定义类型注册应失败")


func test_validate_required_fields() -> void:
	var r := DefSchemaRegistry.new()
	r.define_schema(&"weatheref", ["id", "kind"])
	assert_false(r.register_def(&"weatheref", "bad", {"id": "bad"}), "缺必需字段应失败")


func test_validator_rejects() -> void:
	var r := DefSchemaRegistry.new()
	r.define_schema(&"weatheref", ["weight"], func(d): return d["weight"] >= 0.0)
	assert_false(r.register_def(&"weatheref", "neg", {"weight": -1.0}), "validator 拒绝应失败")
	assert_true(r.register_def(&"weatheref", "pos", {"weight": 2.0}), "validator 通过应成功")


func test_get_and_list() -> void:
	var r := DefSchemaRegistry.new()
	r.define_schema(&"weatheref", ["id"])
	r.register_def(&"weatheref", "a", {"id": "a"})
	r.register_def(&"weatheref", "b", {"id": "b"})
	assert_eq(r.list_defs(&"weatheref").size(), 2, "list_defs 应返回 2 项")
	assert_true(r.list_types().has(&"weatheref"), "list_types 应包含自定义类型")
	assert_eq(r.get_def(&"weatheref", "missing"), {}, "缺失实例应返回空字典")


func test_duplicate_schema_rejected() -> void:
	var r := DefSchemaRegistry.new()
	r.define_schema(&"t", ["a"])
	assert_false(r.define_schema(&"t", ["b"]), "重复定义 schema 应失败")
