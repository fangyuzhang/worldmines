# settings_registry.gd —— Mod 设置项注册（文档 23 号 §14.11）
# Mod 声明设置项 → 自动出现在设置页「Mod」分区，自动持久化（由宿主负责落盘，本类只管存取）。
class_name SettingsRegistry
extends RefCounted


# id(String) -> { type: String, value: Variant, default: Variant, label: String }
var _items: Dictionary = {}


## 注册一个设置项。返回是否成功（空 id / 已存在则失败）。
func register(id: String, type: String, default_value: Variant, label: String) -> bool:
	if id == "" or _items.has(id):
		return false
	_items[id] = {"type": type, "value": default_value, "default": default_value, "label": label}
	return true


## 读设置项当前值（未注册返回 null）。
func get_value(id: String) -> Variant:
	if not _items.has(id):
		return null
	return _items[id]["value"]


## 写设置项值。
func set_value(id: String, value: Variant) -> void:
	if _items.has(id):
		_items[id]["value"] = value


## 重置为默认。
func reset(id: String) -> void:
	if _items.has(id):
		_items[id]["value"] = _items[id]["default"]


## 列出全部设置项（供设置页渲染）。
func list() -> Array:
	var out: Array = []
	for id in _items:
		var item: Dictionary = _items[id].duplicate(true)
		item["id"] = id
		out.append(item)
	return out


## 清空全部。
func clear() -> void:
	_items.clear()
