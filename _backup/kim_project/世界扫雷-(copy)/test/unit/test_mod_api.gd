# test_mod_api.gd —— ModAPI 门面测试（文档 23 号 §四 / §14.2 / 21 号 R32）
extends GutTest


class FakeRenderer extends RefCounted:
	var _id: StringName
	func _init(id: StringName = &"r1") -> void:
		_id = id
	func get_id() -> StringName:
		return _id
	func render(_frame: Variant) -> void:
		pass
	func supports() -> bool:
		return true


const TEST_MOD_DIR := "user://_mod_api_test"


func _write_manifest(runtime: String, capabilities: Array = [], mod_id: String = "test.mod") -> String:
	var dir := TEST_MOD_DIR
	DirAccess.make_dir_recursive_absolute(dir)
	var m := {
		"id": mod_id, "version": "1.0.0",
		"entry": {"runtime": runtime, "path": "mod.gd"},
		"capabilities": capabilities,
	}
	var f := FileAccess.open(dir.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(m))
	f.close()
	return dir


func after_each() -> void:
	var d := DirAccess.open(TEST_MOD_DIR)
	if d != null:
		d.remove("manifest.json")


func test_define_and_register_extension() -> void:
	var api := ModAPI.new()
	api.define_extension(&"hexworks.ReplayRenderer", ["render", "supports"])
	var r := FakeRenderer.new()
	assert_true(api.register_extension(&"hexworks.ReplayRenderer", r), "自举扩展点应可注册")
	assert_eq(api.first_extension(&"hexworks.ReplayRenderer"), r, "可取到实现")
	assert_true(api.list_extensions().has(&"hexworks.ReplayRenderer"), "自举扩展点应在列表中")


func test_each_extension() -> void:
	var api := ModAPI.new()
	api.define_extension(&"p", ["render"])
	var a := FakeRenderer.new(&"a")
	var b := FakeRenderer.new(&"b")
	api.register_extension(&"p", a, 50)
	api.register_extension(&"p", b, 90)
	var seen: Array = []
	api.each_extension(&"p", func(impl): seen.append(impl))
	assert_eq(seen.size(), 2, "each 应遍历全部实现")
	assert_eq(seen[0], b, "应按 priority 降序")


func test_load_def_mod() -> void:
	var api := ModAPI.new()
	var dir := _write_manifest("def", [])
	var r := api.load_mod(dir)
	assert_true(r["ok"], "def runtime Mod 应可加载")
	assert_true(api.list_mods().has("test.mod"), "应记录在 list_mods")


func test_load_reject_missing_manifest() -> void:
	var api := ModAPI.new()
	DirAccess.make_dir_recursive_absolute(TEST_MOD_DIR.path_join("empty"))
	var r := api.load_mod(TEST_MOD_DIR.path_join("empty"))
	assert_false(r["ok"], "缺 manifest 应失败")


func test_load_reject_never_capability() -> void:
	var api := ModAPI.new()
	var dir := _write_manifest("def", ["board.write_answer", "board.read"])
	var r := api.load_mod(dir)
	assert_true(r["ok"], "Mod 本身仍应加载")
	assert_true(r["rejected"].has(&"board.write_answer"), "永不授予能力应进 rejected")
	assert_false(api.has_capability("test.mod", &"board.write_answer"), "永不授予能力不可用")


func test_has_capability() -> void:
	var api := ModAPI.new()
	var dir := _write_manifest("def", ["clue.register"])
	api.load_mod(dir)
	assert_true(api.has_capability("test.mod", &"clue.register"), "声明能力应可用")
	assert_true(api.has_capability("test.mod", &"board.read"), "默认能力应可用")
	assert_false(api.has_capability("test.mod", &"ui.inject"), "未声明能力应不可用")
	assert_false(api.has_capability("unknown.mod", &"board.read"), "未知 Mod 应无能力")


func test_unload_mod() -> void:
	var api := ModAPI.new()
	var dir := _write_manifest("def", [])
	api.load_mod(dir)
	assert_true(api.unload_mod("test.mod")["ok"], "unload 应成功")
	assert_false(api.list_mods().has("test.mod"), "unload 后应从 list_mods 移除")


func test_service_registry_via_api() -> void:
	var api := ModAPI.new()
	var svc := RefCounted.new()
	api.services.provide(&"hex.Math", svc)
	assert_eq(api.services.get_service(&"hex.Math"), svc, "ModAPI.services 应可达 ServiceRegistry")


func test_sensitive_capability_requires_grant() -> void:
	var api := ModAPI.new()
	var dir := _write_manifest("def", ["ui.inject"])
	api.load_mod(dir)
	assert_false(api.has_capability("test.mod", &"ui.inject"), "敏感能力未授权应不可用")
	api.grants.grant(&"ui.inject")
	assert_true(api.has_capability("test.mod", &"ui.inject"), "授权后应可用")


func test_mod_info_deep_copy() -> void:
	var api := ModAPI.new()
	var dir := _write_manifest("def", [])
	api.load_mod(dir)
	var info := api.mod_info("test.mod")
	info["capabilities"].append(&"board.write_answer")
	assert_false(api.has_capability("test.mod", &"board.write_answer"), "篡改 mod_info 副本不应越权")
