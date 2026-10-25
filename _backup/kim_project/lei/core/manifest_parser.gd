# manifest_parser.gd —— manifest.json 解析与校验（文档 23 号 §2.1）
# Mod 元数据入口：id / version / api_version / entry（runtime+path）/ capabilities / plugins /
# provides / dependencies / conflicts / requires_color_scheme / content_hash。
class_name ManifestParser
extends RefCounted


## 本平台当前 API 版本（用于兼容性检查）。
const API_VERSION := "2.9"

## entry.runtime 合法取值。
const RUNTIME_WASM := "wasm"
const RUNTIME_GDScript := "gdscript"
const RUNTIME_DEF := "def"


## 从 JSON 文本解析 manifest。返回 { ok, manifest, reason }。
func parse(json_text: String) -> Dictionary:
	# 用 JSON.new().parse() 而非 parse_string：parse_string 对非法 JSON 会 push_error（引擎错误）。
	var json := JSON.new()
	if json.parse(json_text) != OK:
		return {"ok": false, "reason": "JSON 解析失败"}
	var data: Variant = json.data
	if not (data is Dictionary):
		return {"ok": false, "reason": "JSON 顶层必须是对象"}
	return validate(data)


## 校验并规范化 manifest 字典。返回 { ok, manifest, reason }。
func validate(manifest: Dictionary) -> Dictionary:
	# 必填：id
	var id: String = str(manifest.get("id", ""))
	if id == "":
		return {"ok": false, "reason": "缺少 id"}
	# 必填：version（语义版本）
	var version: String = str(manifest.get("version", ""))
	if version == "":
		return {"ok": false, "reason": "缺少 version"}
	# 必填：entry
	var entry: Variant = manifest.get("entry", {})
	if not (entry is Dictionary):
		return {"ok": false, "reason": "缺少 entry"}
	var runtime: String = str(entry.get("runtime", ""))
	if not [RUNTIME_WASM, RUNTIME_GDScript, RUNTIME_DEF].has(runtime):
		return {"ok": false, "reason": "entry.runtime 非法: %s" % runtime}
	var path: String = str(entry.get("path", ""))
	if path == "":
		return {"ok": false, "reason": "缺少 entry.path"}

	# 规范化副本（不污染输入）
	var m := manifest.duplicate(true)
	m["id"] = id
	m["version"] = version
	m["entry"] = {"runtime": runtime, "path": path}

	# capabilities → Array[StringName]（先校验必须是数组，否则拒绝）
	var caps_raw: Variant = m.get("capabilities", [])
	if not (caps_raw is Array):
		return {"ok": false, "reason": "capabilities 必须是数组"}
	var caps: Array[StringName] = []
	for c in caps_raw:
		caps.append(StringName(str(c)))
	m["capabilities"] = caps

	# api_version 兼容性（major 一致即可，当前 API 2.x）
	var api_version: String = str(manifest.get("api_version", ""))
	if api_version != "" and not api_version.begins_with("2."):
		return {"ok": false, "reason": "API 版本不兼容: %s" % api_version}

	# dependencies / conflicts → Array[String]（保证存在）
	if not m.has("dependencies"):
		m["dependencies"] = []
	if not m.has("conflicts"):
		m["conflicts"] = []
	if not m.has("provides"):
		m["provides"] = {}
	if not m.has("plugins"):
		m["plugins"] = []

	return {"ok": true, "manifest": m, "reason": ""}
