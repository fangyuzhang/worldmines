# service_registry.gd —— 服务注册表（文档 23 号 §14.3）
# 自举支柱之一：Mod 之间互相提供服务、消费服务，不依赖平台预判。
# provide 暴露服务；get 消费服务（未提供 / 版本不匹配返回 null，消费方须有 fallback，S5）。
class_name ServiceRegistry
extends RefCounted


# service_id(StringName) -> { impl: Object, version: String, provider: StringName }
var _services: Dictionary = {}


## 提供服务。version 为语义版本字符串（如 "1.2.0"）；provider 为 Mod id（可选，用于溯源）。
## 返回是否成功（impl 为 null 或 service_id 为空则失败）。
## 防服务劫持：已存在且提供方不同（且原提供方非空）→ 拒绝覆盖；同提供方允许更新。
func provide(service_id: StringName, impl: Object, version: String = "1.0.0", provider: StringName = &"") -> bool:
	if impl == null or service_id == &"":
		return false
	if _services.has(service_id):
		var existing_provider: StringName = _services[service_id]["provider"]
		if existing_provider != &"" and existing_provider != provider:
			return false
	_services[service_id] = {"impl": impl, "version": version, "provider": provider}
	return true


## 消费服务。required_version 为空时返回任意版本；否则做语义版本匹配（major 必须相等且版本 >= 要求）。
## 无服务 / 版本不匹配返回 null —— 调用方必须处理 null 走降级（S5）。
## 命名 get_service 以免覆盖 Object.get()（覆盖内置方法且签名不符会导致整个类编译失败）。
func get_service(service_id: StringName, required_version: String = "") -> Variant:
	if not _services.has(service_id):
		return null
	var entry: Dictionary = _services[service_id]
	if required_version == "" or _version_satisfies(str(entry["version"]), required_version):
		return entry["impl"]
	return null


## 服务是否存在。
func has(service_id: StringName) -> bool:
	return _services.has(service_id)


## 移除服务。返回是否找到并移除。
func unprovide(service_id: StringName) -> bool:
	if not _services.has(service_id):
		return false
	_services.erase(service_id)
	return true


## 服务元数据（impl/version/provider）；无则空字典。
func info(service_id: StringName) -> Dictionary:
	return _services.get(service_id, {})


## 列出所有已注册服务 id。
func list_services() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _services:
		out.append(id)
	return out


## 清空全部服务。
func clear() -> void:
	_services.clear()


## 语义版本匹配：major 相等且 actual >= required（比较 minor.patch）。
func _version_satisfies(actual: String, required: String) -> bool:
	var a := _parse_version(actual)
	var r := _parse_version(required)
	if a.is_empty() or r.is_empty():
		return false
	if a[0] != r[0]:          # major 不兼容
		return false
	if a[1] > r[1]:
		return true
	if a[1] < r[1]:
		return false
	return a[2] >= r[2]


## 解析 "major.minor.patch" -> [major, minor, patch]；非法返回空数组。
func _parse_version(v: String) -> Array:
	var parts := v.split(".")
	if parts.is_empty():
		return []
	var out: Array = []
	for i in range(3):
		if i < parts.size():
			out.append(int(parts[i]))
		else:
			out.append(0)
	return out
