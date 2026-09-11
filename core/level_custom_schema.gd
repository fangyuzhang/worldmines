# level_custom_schema.gd —— pz3 custom 数据模型扩展（文档 23 号 §15.4）
# 引擎级原语之一：关卡 JSON 的 custom 扩展区（2E 的字母表/初始映射提示等放这里）。
# custom 必须通过 custom_schema 声明的校验器；未声明 schema → 忽略该 custom 并警告。
# 校验器由 Mod 提供，平台只做"必须声明 schema + 校验通过才加载"。
class_name LevelCustomSchema
extends RefCounted


# schema_id(String) -> validator(Callable)
var _schemas: Dictionary = {}


## 注册一个 custom 校验器。schema_id 形如 "workshop.2e@1.0/schema.json"。
## validator 接收 custom 字典，返回 bool（是否通过）。
func register(schema_id: String, validator: Callable) -> bool:
	if schema_id == "" or not validator.is_valid() or _schemas.has(schema_id):
		return false
	_schemas[schema_id] = validator
	return true


## 校验 custom。schema_id 未注册返回 false（未声明 schema → 忽略）。
func validate(schema_id: String, custom: Dictionary) -> bool:
	if not _schemas.has(schema_id):
		return false
	return bool(_schemas[schema_id].call(custom))


## 是否已注册。
func has(schema_id: String) -> bool:
	return _schemas.has(schema_id)


## 列出全部 schema id。
func list() -> Array[String]:
	var out: Array[String] = []
	for id in _schemas:
		out.append(id)
	out.sort()
	return out


## 清空。
func clear() -> void:
	_schemas.clear()
