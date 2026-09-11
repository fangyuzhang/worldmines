# def_schema.gd —— 自定义 Def 类型注册（文档 23 号 §14.7）
# 四类内置 Def（clue / cell / grid / constraint）不是上限：
# Mod 可用 define_schema 注册全新的 Def 类型，register_def 注册实例并自动做 schema 校验。
class_name DefSchemaRegistry
extends RefCounted


# type_name(StringName) -> { required_fields: Array[String], validator: Callable }
var _schemas: Dictionary = {}
# type_name(StringName) -> { def_name(String) -> def(Dictionary) }
var _defs: Dictionary = {}


## 定义一个新的 Def 类型。required_fields：实例必须拥有的字段名；validator：可选校验函数。
## 返回是否成功（type_name 为空 / 已存在则失败）。
func define_schema(type_name: StringName, required_fields: Array, validator: Callable = Callable()) -> bool:
	if type_name == &"" or _schemas.has(type_name):
		return false
	var fields: Array[String] = []
	for f in required_fields:
		fields.append(str(f))
	_schemas[type_name] = {"required_fields": fields, "validator": validator}
	if not _defs.has(type_name):
		_defs[type_name] = {}
	return true


## 注册一个 Def 实例（自动 schema 校验）。返回是否成功。
func register_def(type_name: StringName, def_name: String, def: Dictionary) -> bool:
	if not _schemas.has(type_name):
		return false
	if def_name == "" or not validate(type_name, def):
		return false
	_defs[type_name][def_name] = def
	return true


## 校验 def 是否满足 schema（必需字段存在 + validator 通过）。
func validate(type_name: StringName, def: Dictionary) -> bool:
	if not _schemas.has(type_name):
		return false
	var schema: Dictionary = _schemas[type_name]
	for f in schema["required_fields"]:
		if not def.has(f):
			return false
	var validator: Callable = schema["validator"]
	if validator.is_valid() and not bool(validator.call(def)):
		return false
	return true


## 取某类型下的 Def 实例（无则空字典）。
func get_def(type_name: StringName, def_name: String) -> Dictionary:
	if not _defs.has(type_name):
		return {}
	return _defs[type_name].get(def_name, {})


## 列出某类型下的全部 Def 名。
func list_defs(type_name: StringName) -> Array[String]:
	var out: Array[String] = []
	if _defs.has(type_name):
		for name in _defs[type_name]:
			out.append(name)
	out.sort()
	return out


## 列出全部已注册的 Def 类型名。
func list_types() -> Array[StringName]:
	var out: Array[StringName] = []
	for t in _schemas:
		out.append(t)
	return out


## 清空全部 schema 与 def。
func clear() -> void:
	_schemas.clear()
	_defs.clear()
