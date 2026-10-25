# test_manifest_parser.gd —— ManifestParser 测试（文档 23 号 §2.1）
extends GutTest


func _valid_manifest() -> Dictionary:
	return {
		"id": "workshop.hex-mines",
		"name": "六边形扫雷",
		"version": "1.0.0",
		"api_version": "2.9",
		"entry": {"runtime": "gdscript", "path": "mod.gd"},
		"capabilities": ["board.read", "clue.register"],
	}


func test_parse_valid() -> void:
	var p := ManifestParser.new()
	var r := p.parse(JSON.stringify(_valid_manifest()))
	assert_true(r["ok"], "合法 manifest 应通过")
	assert_eq(r["manifest"]["id"], "workshop.hex-mines", "id 应保留")


func test_parse_invalid_json() -> void:
	var p := ManifestParser.new()
	assert_false(p.parse("{not json")["ok"], "非法 JSON 应失败")


func test_missing_id() -> void:
	var p := ManifestParser.new()
	var m := _valid_manifest()
	m.erase("id")
	assert_false(p.validate(m)["ok"], "缺 id 应失败")


func test_missing_version() -> void:
	var p := ManifestParser.new()
	var m := _valid_manifest()
	m.erase("version")
	assert_false(p.validate(m)["ok"], "缺 version 应失败")


func test_missing_entry() -> void:
	var p := ManifestParser.new()
	var m := _valid_manifest()
	m.erase("entry")
	assert_false(p.validate(m)["ok"], "缺 entry 应失败")


func test_invalid_runtime() -> void:
	var p := ManifestParser.new()
	var m := _valid_manifest()
	m["entry"] = {"runtime": "lua", "path": "mod.lua"}
	assert_false(p.validate(m)["ok"], "非法 runtime 应失败")


func test_capabilities_normalized() -> void:
	var p := ManifestParser.new()
	var r := p.validate(_valid_manifest())
	var caps: Array = r["manifest"]["capabilities"]
	assert_eq(caps.size(), 2, "capabilities 应保留两项")
	assert_true(caps[0] is StringName, "capabilities 应规范化为 StringName")


func test_defaults_filled() -> void:
	var p := ManifestParser.new()
	var m := _valid_manifest()
	var r := p.validate(m)
	var manifest: Dictionary = r["manifest"]
	assert_true(manifest.has("dependencies"), "dependencies 应有默认值")
	assert_true(manifest.has("conflicts"), "conflicts 应有默认值")
	assert_true(manifest.has("provides"), "provides 应有默认值")
	assert_true(manifest.has("plugins"), "plugins 应有默认值")
